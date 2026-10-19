import 'dart:convert';

import 'package:appflowy/plugins/database/application/cell/cell_controller.dart';
import 'package:appflowy/plugins/database/application/field/type_option/select_type_option_actions.dart';
import 'package:appflowy/plugins/database/application/row/row_service.dart';
import 'package:appflowy/plugins/database/domain/cell_service.dart';
import 'package:appflowy/plugins/database/domain/date_cell_service.dart';
import 'package:appflowy/plugins/database/domain/field_service.dart';
import 'package:appflowy/plugins/database/domain/select_option_cell_service.dart';
import 'package:appflowy/workspace/application/view/view_service.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-database2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';
import 'package:nanoid/nanoid.dart';

/// Field types the assistant can write, by the name the AI uses. Every other
/// type is read-only.
final dbTypeNames = <FieldType, String>{
  FieldType.RichText: 'text',
  FieldType.Number: 'number',
  FieldType.DateTime: 'date',
  FieldType.SingleSelect: 'select',
  FieldType.MultiSelect: 'multi_select',
  FieldType.Checkbox: 'checkbox',
};

/// The option names in a select cell's text: none when empty; multi-select
/// text is comma-separated.
List<String> selectNames(FieldType type, String text) => text.trim().isEmpty
    ? const []
    : type == FieldType.MultiSelect
        ? [
            for (final n in text.split(','))
              if (n.trim().isNotEmpty) n.trim(),
          ]
        : [text.trim()];

/// Date cell text: `YYYY-MM-DD`, plus ` HH:MM` when the cell includes a time;
/// a range is `<start> → <end>` (read-only).
bool isDateRange(String text) => text.contains(' → ');

final _dateText = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?: (\d{2}):(\d{2}))?$');

/// [text] (see [isDateRange]) as a local date, null when it isn't one.
/// `.time` tells whether it had a time of day.
({DateTime date, bool time})? parseDateText(String text) {
  final m = _dateText.firstMatch(text);
  if (m == null) return null;
  final n = [for (var i = 1; i <= 5; i++) int.tryParse(m[i] ?? '') ?? 0];
  final d = DateTime(n[0], n[1], n[2], n[3], n[4]);
  final ok = d.year == n[0] &&
      d.month == n[1] &&
      d.day == n[2] &&
      d.hour == n[3] &&
      d.minute == n[4];
  return ok ? (date: d, time: m[4] != null) : null;
}

class DbField {
  const DbField({
    required this.id,
    required this.name,
    required this.type,
    required this.writable,
    this.options = const [],
  });

  final String id, name;
  final FieldType type;
  final bool writable;
  final List<({String id, String name})> options;
}

class DbSnapshot {
  const DbSnapshot({
    required this.id,
    required this.name,
    required this.layout,
    required this.fields,
    required this.rows,
    this.isLocked = false,
  });

  final String id, name;
  final ViewLayoutPB layout;

  /// Locked databases are read-only.
  final bool isLocked;

  /// The primary field first.
  final List<DbField> fields;

  /// Cell text by field id, for every field (empty when blank).
  final List<({String id, Map<String, String> cells})> rows;
}

const _dbLayouts = [
  ViewLayoutPB.Grid,
  ViewLayoutPB.Board,
  ViewLayoutPB.Calendar,
];

/// Thin wrapper over the database services; not unit-tested. Every failed
/// backend call throws. Cell text: select = option names (multi: ", "),
/// checkbox = Yes/No, date = YYYY-MM-DD; [_write] takes the same text back.
class DatabaseGateway {
  Future<List<({String id, String name, ViewLayoutPB layout, bool isLocked})>>
      databases() async {
    final views = (await ViewBackendService.getAllViews()).getOrThrow().items;
    return [
      for (final v in views)
        if (_dbLayouts.contains(v.layout))
          (id: v.id, name: v.name, layout: v.layout, isLocked: v.isLocked),
    ];
  }

  /// Null when the database is gone. Cells are read for the first [rowCap]
  /// rows only.
  Future<DbSnapshot?> snapshot(String dbId, {int rowCap = 200}) async {
    final db = (await databases()).where((d) => d.id == dbId).firstOrNull;
    if (db == null) return null;
    final fields = await _fields(dbId);
    return DbSnapshot(
      id: dbId,
      name: db.name,
      layout: db.layout,
      isLocked: db.isLocked,
      fields: [
        for (final f in fields)
          DbField(
            id: f.id,
            name: f.name,
            type: f.fieldType,
            writable: dbTypeNames.containsKey(f.fieldType),
            options: [for (final o in _options(f)) (id: o.id, name: o.name)],
          ),
      ],
      rows: [
        for (final id in (await _rowIds(dbId)).take(rowCap))
          (id: id, cells: await _cells(dbId, id, fields)),
      ],
    );
  }

  /// Null when the row or its database is gone.
  Future<Map<String, String>?> row(String dbId, String rowId) async {
    if ((await databases()).every((d) => d.id != dbId)) return null;
    if (!(await _rowIds(dbId)).contains(rowId)) return null;
    return _cells(dbId, rowId, await _fields(dbId));
  }

  /// A database under [parentId] with exactly [fields], in order, and no
  /// rows; returns its id and the field ids in [fields] order. The template's
  /// primary field is renamed to the first field when that is text (else it
  /// stays). A board keeps its group field and a calendar its date field,
  /// reused for the first field of that type (a reused select starts with no
  /// options). Every other template field goes. Deletes the view again if
  /// any step fails.
  Future<({String id, List<String> fieldIds})> createDatabase(
    String parentId,
    String name,
    ViewLayoutPB layout,
    List<({String name, FieldType type})> fields,
  ) async {
    final parent = (await ViewBackendService.getView(parentId)).getOrThrow();
    if (parent.isLocked) throw StateError('Parent is locked');
    final view = (await ViewBackendService.createView(
      layoutType: layout,
      parentViewId: parentId,
      name: name,
    ))
        .getOrThrow();
    try {
      final rows = await _rowIds(view.id);
      if (rows.isNotEmpty) {
        (await RowBackendService.deleteRows(view.id, rows)).getOrThrow();
      }
      final template = await _fields(view.id);
      final keepType = switch (layout) {
        ViewLayoutPB.Board => FieldType.SingleSelect,
        ViewLayoutPB.Calendar => FieldType.DateTime,
        _ => null,
      };
      var keep =
          template.skip(1).where((f) => f.fieldType == keepType).firstOrNull;
      for (final f in template.skip(1)) {
        if (f.id != keep?.id) await removeField(view.id, f.id);
      }
      final ids = <String>[];
      for (final (i, f) in fields.indexed) {
        final reuse = i == 0 && f.type == FieldType.RichText
            ? template.first
            : keep?.fieldType == f.type
                ? keep
                : null;
        if (reuse == null) {
          ids.add(await addField(view.id, f.name, f.type));
          continue;
        }
        if (reuse == keep) {
          keep = null;
          if (f.type == FieldType.SingleSelect) {
            await _setOptions(view.id, reuse, const []);
          }
        }
        await renameField(view.id, reuse.id, f.name);
        ids.add(reuse.id);
      }
      return (id: view.id, fieldIds: ids);
    } catch (_) {
      final r = await ViewBackendService.deleteView(viewId: view.id);
      r.onFailure(
        (e) => Log.warn('Could not clean up database ${view.id}: $e'),
      );
      rethrow;
    }
  }

  /// To Trash.
  Future<void> deleteDatabase(String dbId) async =>
      (await ViewBackendService.deleteView(viewId: dbId)).getOrThrow();

  /// A row holding [cells]; the row is deleted again if a write fails.
  Future<String> addRow(String dbId, Map<String, String> cells) async {
    final id =
        (await RowBackendService.createRow(viewId: dbId)).getOrThrow().id;
    try {
      final fields = await _fields(dbId);
      for (final e in cells.entries) {
        await _write(dbId, id, fields, e.key, e.value);
      }
    } catch (_) {
      final r = await RowBackendService.deleteRows(dbId, [id]);
      r.onFailure((e) => Log.warn('Could not clean up row $id: $e'));
      rethrow;
    }
    return id;
  }

  /// If a write fails, the cells already written are put back first.
  Future<void> updateRow(
    String dbId,
    String rowId,
    Map<String, String> cells,
  ) async {
    final fields = await _fields(dbId);
    final before = await _cells(dbId, rowId, fields);
    final touched = <String>[];
    try {
      for (final e in cells.entries) {
        touched.add(e.key);
        await _write(dbId, rowId, fields, e.key, e.value);
      }
    } catch (_) {
      for (final k in touched) {
        try {
          await _write(dbId, rowId, fields, k, before[k] ?? '');
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> removeRow(String dbId, String rowId) async =>
      (await RowBackendService.deleteRows(dbId, [rowId])).getOrThrow();

  /// True when the row has a page with content, an icon, a cover or files:
  /// things a re-created row would lose.
  Future<bool> rowHasExtras(String dbId, String rowId) async {
    final m =
        (await RowBackendService(viewId: dbId).getRowMeta(rowId)).getOrThrow();
    return !m.isDocumentEmpty ||
        m.icon.isNotEmpty ||
        m.hasCover() && m.cover.data.isNotEmpty ||
        m.attachmentCount > 0;
  }

  Future<String> addField(String dbId, String name, FieldType type) async =>
      (await FieldBackendService.createField(
        viewId: dbId,
        fieldType: type,
        fieldName: name,
      ))
          .getOrThrow()
          .id;

  Future<void> renameField(String dbId, String fieldId, String name) async =>
      (await FieldBackendService(viewId: dbId, fieldId: fieldId)
              .updateField(name: name))
          .getOrThrow();

  Future<void> removeField(String dbId, String fieldId) async =>
      (await FieldBackendService.deleteField(viewId: dbId, fieldId: fieldId))
          .getOrThrow();

  /// A type-option write, so no row is touched; returns the new option's id.
  Future<String> addOption(String dbId, String fieldId, String name) async {
    final f = await _field(dbId, fieldId);
    final options = _options(f);
    final o = SelectOptionPB(
      id: nanoid(4),
      name: name,
      color: newSelectOptionColor(options),
    );
    await _setOptions(dbId, f, [...options, o]);
    return o.id;
  }

  Future<void> removeOption(
    String dbId,
    String fieldId,
    String optionId,
  ) async {
    final f = await _field(dbId, fieldId);
    await _setOptions(dbId, f, [
      for (final o in _options(f))
        if (o.id != optionId) o,
    ]);
  }

  /// Primary first.
  Future<List<FieldPB>> _fields(String dbId) async {
    final all =
        (await FieldBackendService.getFields(viewId: dbId)).getOrThrow();
    return [
      ...all.where((f) => f.isPrimary),
      ...all.where((f) => !f.isPrimary),
    ];
  }

  Future<FieldPB> _field(String dbId, String fieldId) async =>
      (await _fields(dbId)).where((f) => f.id == fieldId).firstOrNull ??
      (throw StateError('Field not found'));

  Future<List<String>> _rowIds(String dbId) async => [
        for (final r in (await DatabaseEventGetAllRows(
          DatabaseViewIdPB(value: dbId),
        ).send())
            .getOrThrow()
            .items)
          r.id,
      ];

  Future<List<int>> _cell(String dbId, String rowId, String fieldId) async =>
      (await CellBackendService.getCell(
        viewId: dbId,
        cellContext: CellContext(fieldId: fieldId, rowId: rowId),
      ))
          .getOrThrow()
          .data;

  Future<Map<String, String>> _cells(
    String dbId,
    String rowId,
    List<FieldPB> fields,
  ) async =>
      {
        for (final f in fields)
          f.id: _text(f.fieldType, await _cell(dbId, rowId, f.id)),
      };

  Future<void> _write(
    String dbId,
    String rowId,
    List<FieldPB> fields,
    String fieldId,
    String text,
  ) async {
    final f = fields.where((x) => x.id == fieldId).firstOrNull ??
        (throw StateError('Field not found'));
    switch (f.fieldType) {
      case FieldType.RichText || FieldType.Number || FieldType.Checkbox:
        (await CellBackendService.updateCell(
          viewId: dbId,
          cellContext: CellContext(fieldId: fieldId, rowId: rowId),
          data: text,
        ))
            .getOrThrow();
      case FieldType.DateTime:
        final s = DateCellBackendService(
          viewId: dbId,
          fieldId: fieldId,
          rowId: rowId,
        );
        final cur =
            DateCellDataPB.fromBuffer(await _cell(dbId, rowId, fieldId));
        if (cur.isRange) throw StateError('${f.name} is a date range');
        if (text.isEmpty) {
          (await s.clear()).getOrThrow();
          return;
        }
        final w = dateWrite(text, cur);
        (await s.update(date: w.date, includeTime: w.includeTime)).getOrThrow();
      case FieldType.SingleSelect || FieldType.MultiSelect:
        final byName = {
          for (final o in _options(f)) o.name.toLowerCase(): o.id,
        };
        final want = {
          for (final n in selectNames(f.fieldType, text))
            byName[n.toLowerCase()] ?? (throw StateError('No option $n')),
        };
        final have = {
          for (final o in SelectOptionCellDataPB.fromBuffer(
            await _cell(dbId, rowId, fieldId),
          ).selectOptions)
            o.id,
        };
        final s = SelectOptionCellBackendService(
          viewId: dbId,
          fieldId: fieldId,
          rowId: rowId,
        );
        final add = want.difference(have), drop = have.difference(want);
        if (add.isNotEmpty) (await s.select(optionIds: add)).getOrThrow();
        if (drop.isNotEmpty) (await s.unselect(optionIds: drop)).getOrThrow();
      default:
        throw StateError('${f.name} is read-only');
    }
  }

  List<SelectOptionPB> _options(FieldPB f) => switch (f.fieldType) {
        FieldType.SingleSelect =>
          SingleSelectTypeOptionPB.fromBuffer(f.typeOptionData).options,
        FieldType.MultiSelect =>
          MultiSelectTypeOptionPB.fromBuffer(f.typeOptionData).options,
        _ => const [],
      };

  /// Rewrites the field's type option with [options], keeping its settings.
  Future<void> _setOptions(
    String dbId,
    FieldPB f,
    List<SelectOptionPB> options,
  ) async {
    final List<int> data;
    if (f.fieldType == FieldType.MultiSelect) {
      final pb = MultiSelectTypeOptionPB.fromBuffer(f.typeOptionData);
      data = (pb
            ..options.clear()
            ..options.addAll(options))
          .writeToBuffer();
    } else {
      final pb = SingleSelectTypeOptionPB.fromBuffer(f.typeOptionData);
      data = (pb
            ..options.clear()
            ..options.addAll(options))
          .writeToBuffer();
    }
    (await FieldBackendService.updateFieldTypeOption(
      viewId: dbId,
      fieldId: f.id,
      typeOptionData: data,
    ))
        .getOrThrow();
  }
}

DateTime _local(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

/// What writing [text] to a date cell holding [cur] sends: a time sets
/// includeTime; a date-only text keeps the cell's time of day and leaves
/// includeTime as it is (null).
({DateTime date, bool? includeTime}) dateWrite(
  String text,
  DateCellDataPB cur,
) {
  final v = parseDateText(text) ?? (throw StateError('Bad date $text'));
  if (v.time) return (date: v.date, includeTime: true);
  if (!cur.includeTime || !cur.hasTimestamp()) {
    return (date: v.date, includeTime: null);
  }
  final old = _local(cur.timestamp.toInt());
  final d = v.date;
  return (
    date: DateTime(d.year, d.month, d.day, old.hour, old.minute),
    includeTime: null,
  );
}

/// See [isDateRange].
String dateCellText(DateCellDataPB d) {
  if (!d.hasTimestamp()) return '';
  String one(int seconds) {
    final t = _local(seconds).toIso8601String();
    return d.includeTime
        ? '${t.substring(0, 10)} ${t.substring(11, 16)}'
        : t.substring(0, 10);
  }

  final start = one(d.timestamp.toInt());
  return d.isRange ? '$start → ${one(d.endTimestamp.toInt())}' : start;
}

/// Best-effort text of a cell. Unreadable data reads as "?", so it counts as
/// non-empty (a row holding it is never removed).
String _text(FieldType type, List<int> data) {
  String count(int n, String what) => n == 0 ? '' : '$n $what';
  try {
    return switch (type) {
      FieldType.Checkbox =>
        CheckboxCellDataPB.fromBuffer(data).isChecked ? 'Yes' : 'No',
      FieldType.SingleSelect ||
      FieldType.MultiSelect =>
        SelectOptionCellDataPB.fromBuffer(data)
            .selectOptions
            .map((o) => o.name)
            .join(', '),
      FieldType.DateTime => dateCellText(DateCellDataPB.fromBuffer(data)),
      FieldType.URL => URLCellDataPB.fromBuffer(data).content,
      FieldType.CreatedTime ||
      FieldType.LastEditedTime =>
        TimestampCellDataPB.fromBuffer(data).dateTime,
      FieldType.Checklist => ChecklistCellDataPB.fromBuffer(data)
          .options
          .map((o) => o.name)
          .join(', '),
      FieldType.Relation =>
        count(RelationCellDataPB.fromBuffer(data).rowIds.length, 'linked'),
      FieldType.Media =>
        count(MediaCellDataPB.fromBuffer(data).files.length, 'files'),
      FieldType.Time => () {
          final t = TimeCellDataPB.fromBuffer(data);
          return t.hasTime() ? '${t.time}' : '';
        }(),
      _ => utf8.decode(data),
    };
  } catch (_) {
    return '?';
  }
}
