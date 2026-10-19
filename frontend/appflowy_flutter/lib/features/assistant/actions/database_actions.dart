import 'package:appflowy/features/assistant/actions/page_content_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/database_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy_backend/protobuf/flowy-database2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';

part 'database_row_actions.dart';

List<ActionHandler> databaseHandlers(DatabaseGateway gw) => [
      _Create(gw),
      _RowAdd(gw),
      _RowUpdate(gw),
      _RowRemove(gw),
      _FieldAdd(gw),
      _FieldRename(gw),
      _OptionAdd(gw),
    ];

const _layouts = {
  'grid': ViewLayoutPB.Grid,
  'board': ViewLayoutPB.Board,
  'calendar': ViewLayoutPB.Calendar,
};

// ponytail: undo checks read every cell of every row; add a per-field read to
// the gateway if databases get large.
const _allRows = 1 << 30;

String? _line(Object? t, String what) {
  if (t is! String || t.trim().isEmpty) return '$what is empty';
  if (t.trim().length > 120 || t.contains(RegExp(r'[\r\n]'))) {
    return '$what is too long';
  }
  return null;
}

/// The trimmed name, checked again at apply (the user may have edited it).
String _mustName(Object? v, {bool noComma = false}) {
  final err = _line(v, 'Name') ??
      (noComma && (v as String).contains(',') ? 'Name has a comma' : null);
  if (err != null) throw StateError(err);
  return (v as String).trim();
}

/// Context cells longer than this are cut, so they become read-only.
const _cellCap = 500;

bool _isRangeIn(FieldType? t, Object? text) =>
    t == FieldType.DateTime && isDateRange('${text ?? ''}');

FieldType? _typeOf(Object? name) =>
    dbTypeNames.entries.where((e) => e.value == name).firstOrNull?.key;

String _typeName(FieldType t) =>
    dbTypeNames[t] ??
    t.name
        .replaceAllMapped(RegExp('(?<=[a-z])[A-Z]'), (m) => '_${m[0]}')
        .toLowerCase();

bool _isSelect(FieldType? t) =>
    t == FieldType.SingleSelect || t == FieldType.MultiSelect;

/// Checkbox "No" is the blank value.
bool _blank(DbField f, String v) =>
    v.isEmpty || f.type == FieldType.Checkbox && v == 'No';

/// Timestamp metadata: regenerated when a row is re-created, so it never
/// blocks a remove.
bool _isMeta(FieldType t) =>
    t == FieldType.CreatedTime || t == FieldType.LastEditedTime;
const _metaNames = {'created_time', 'last_edited_time'};

/// [v] as the gateway writes it into a [type] cell, or null when it doesn't
/// fit (or [type] is read-only). Empty clears the cell.
String? _cellValue(FieldType type, String v) {
  final t = v.trim();
  if (type == FieldType.Checkbox) {
    const map = {'yes': 'Yes', 'true': 'Yes', 'no': 'No', 'false': 'No'};
    return t.isEmpty ? 'No' : map[t.toLowerCase()];
  }
  if (t.isEmpty) return dbTypeNames.containsKey(type) ? '' : null;
  switch (type) {
    case FieldType.RichText:
      return v;
    case FieldType.Number:
      return RegExp(r'^-?\d+(\.\d+)?$').hasMatch(t) ? t : null;
    case FieldType.DateTime:
      return parseDateText(t) == null ? null : t;
    case FieldType.SingleSelect:
      return _line(t, 'Option') == null ? t : null;
    case FieldType.MultiSelect:
      final seen = <String>{};
      final names = [
        for (final n in selectNames(type, t))
          if (seen.add(n.toLowerCase())) n,
      ];
      return names.every((n) => _line(n, 'Option') == null)
          ? names.join(', ')
          : null;
    default:
      return null;
  }
}

/// A database from context (its fields carry its id), or one an earlier
/// action creates.
bool _isDb(ValidationScope s, Object? id) {
  if (s.boundTemps.contains(id)) {
    return s.items[id]?['created_by'] == 'database.create';
  }
  return s.knownIds.contains(id) &&
      s.items.values.any((i) => i['database_id'] == id);
}

/// A field of [db] from context (its item), `{}` for a field an earlier
/// action creates (checked on apply), or null.
Map<String, dynamic>? _field(ValidationScope s, Object? db, Object? id) {
  if (s.boundTemps.contains(id)) {
    final by = s.items[id]?['created_by'];
    return by == null || by == 'field.add' ? const {} : null;
  }
  final item = s.items[id];
  return s.knownIds.contains(id) &&
          item?['database_id'] == db &&
          item?['writable'] != null
      ? item
      : null;
}

bool _isRow(ValidationScope s, Object? db, Object? id) {
  final item = s.items[id];
  if (s.boundTemps.contains(id)) return item?['created_by'] == 'row.add';
  return s.knownIds.contains(id) &&
      item?['database_id'] == db &&
      item?['cells'] != null;
}

/// [row]: the row being changed, when it exists already.
String? _checkCells(
  ValidationScope s,
  Object? db,
  Object? cells, [
  Object? row,
]) {
  final current = s.items[row]?['cells'] as Map?;
  if (cells is! Map || cells.length > 50) return 'Bad cells';
  for (final MapEntry(:key, :value) in cells.entries) {
    if (value is! String || value.length > 2000) return 'Bad cell value';
    final f = _field(s, db, key);
    if (f == null) return 'Unknown field';
    if (f.isEmpty) continue;
    final type = _typeOf(f['type']);
    if (s.readOnlyIds.contains(key) ||
        s.readOnlyIds.contains('$row#$key') ||
        f['writable'] != true ||
        type == null ||
        _isRangeIn(type, current?[key])) {
      return 'Field is read-only';
    }
    if (_cellValue(type, value) == null) return 'Bad value for $key';
  }
  return null;
}

/// The service writes the user's edits to cell keys into `cells`.
Map<String, String> _cellsOf(AssistAction a) => {
      for (final e in (a.fields['cells'] as Map? ?? const {}).entries)
        e.key as String: e.value as String,
    };

abstract class _Base implements ActionHandler {
  _Base(this.gw);
  final DatabaseGateway gw;

  @override
  AssistStage get stage => AssistStage.workspace;

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final id = a.fields['database_id'];
    if (!_isDb(scope, id)) return 'Unknown database_id';
    return scope.readOnlyIds.contains(id) ? 'Database is locked' : null;
  }

  String db(AssistAction a, ApplyScope scope) =>
      scope.resolve(a.fields['database_id'] as String);

  /// Fields only (no rows), or throws if the database is gone or locked (a
  /// lock may be set after the proposal). Call before any write.
  Future<DbSnapshot> mustDb(String id) async {
    final s = await gw.snapshot(id, rowCap: 0);
    if (s == null || s.isLocked) throw StateError("Database can't be edited");
    return s;
  }

  /// For undo: the database, else the outcome to report (gone; locked counts
  /// as changed).
  Future<(DbSnapshot?, UndoOutcome?)> undoDb(
    String id, [
    int rowCap = 0,
  ]) async {
    final s = await gw.snapshot(id, rowCap: rowCap);
    if (s == null) return (null, UndoOutcome.skippedGone);
    if (s.isLocked) return (null, UndoOutcome.skippedChanged);
    return (s, null);
  }

  DbField? field(DbSnapshot s, String id) =>
      s.fields.where((f) => f.id == id).firstOrNull;

  /// [cells] checked against the live fields of [s] (writable, right
  /// shape), with field temps resolved. Select options that don't exist yet
  /// are created first (and stay on undo).
  Future<Map<String, String>> prepare(
    DbSnapshot s,
    Map<String, String> cells,
    ApplyScope scope,
  ) async {
    final dbId = s.id;
    final out = <String, String>{};
    for (final e in cells.entries) {
      final id = scope.resolve(e.key);
      final f = field(s, id) ?? (throw StateError('Field not found'));
      final v = f.writable ? _cellValue(f.type, e.value) : null;
      if (v == null) throw StateError("Can't write ${e.value} to ${f.name}");
      if (_isSelect(f.type)) {
        for (final n in selectNames(f.type, v)) {
          if (!f.options.any((o) => o.name.toLowerCase() == n.toLowerCase())) {
            await gw.addOption(dbId, id, n);
          }
        }
      }
      out[id] = v;
    }
    return out;
  }
}

class _Create extends _Base {
  _Create(super.gw);

  @override
  String get type => 'database.create';

  List<Map> _fields(AssistAction a) => [
        for (final f in (a.fields['fields'] as List? ?? const []))
          if (f is Map) f,
      ];

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final parent = a.fields['parent_id'];
    if (!isPageParent(scope, parent)) return 'Unknown parent_id';
    if (scope.readOnlyIds.contains(parent)) return 'Page is locked';
    if (!_layouts.containsKey(a.fields['layout'])) return 'Unknown layout';
    final fields = a.fields['fields'];
    if (fields is! List || fields.length > 30) return 'Bad fields';
    for (final f in fields) {
      if (f is! Map || _typeOf(f['type']) == null) return 'Bad field';
      final err = _line(f['name'], 'Field name');
      if (err != null) return err;
    }
    return _line(a.fields['name'], 'Name');
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'New ${a.fields['layout']}: ${a.fields['name']} '
            '(${_fields(a).map((f) => f['name']).join(', ')})',
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final fields = _fields(a);
    final r = await gw.createDatabase(
      scope.resolve(a.fields['parent_id'] as String),
      _mustName(a.fields['name']),
      _layouts[a.fields['layout']]!,
      [
        for (final f in fields)
          (name: _mustName(f['name']), type: _typeOf(f['type'])!),
      ],
    );
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, r.id);
    for (final (i, f) in fields.indexed) {
      if (f['temp_id'] case final String t) scope.bind(t, r.fieldIds[i]);
    }
    return UndoRecord(type: type, data: {'database_id': r.id});
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['database_id'] as String;
    final d = (await gw.databases()).where((d) => d.id == id).firstOrNull;
    if (d == null) return UndoOutcome.skippedGone;
    if (d.isLocked) return UndoOutcome.skippedChanged;
    await gw.deleteDatabase(id);
    return UndoOutcome.reverted;
  }
}

class _FieldAdd extends _Base {
  _FieldAdd(super.gw);

  @override
  String get type => 'field.add';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      super.validate(a, scope) ??
      (_typeOf(a.fields['field_type']) == null ? 'Unknown field type' : null) ??
      _line(a.fields['name'], 'Name');

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Add field: ${a.fields['name']} (${a.fields['field_type']})',
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final dbId = db(a, scope);
    final name = _mustName(a.fields['name']);
    await mustDb(dbId);
    final id = await gw.addField(
      dbId,
      name,
      _typeOf(a.fields['field_type'])!,
    );
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, id);
    return UndoRecord(type: type, data: {'database_id': dbId, 'field_id': id});
  }

  /// Only while every cell in it is still empty.
  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final dbId = r.data['database_id'] as String;
    final (s, stop) = await undoDb(dbId, _allRows);
    if (stop != null) return stop;
    final f = field(s!, r.data['field_id'] as String);
    if (f == null) return UndoOutcome.skippedGone;
    if (s.rows.any((row) => !_blank(f, row.cells[f.id] ?? ''))) {
      return UndoOutcome.skippedChanged;
    }
    await gw.removeField(dbId, f.id);
    return UndoOutcome.reverted;
  }
}

class _FieldRename extends _Base {
  _FieldRename(super.gw);

  @override
  String get type => 'field.rename';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      super.validate(a, scope) ??
      (_field(scope, a.fields['database_id'], a.fields['field_id']) == null
          ? 'Unknown field_id'
          : null) ??
      _line(a.fields['name'], 'Name');

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Rename field',
        before: labels[a.fields['field_id']] ?? '',
        after: a.fields['name'] as String?,
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final dbId = db(a, scope);
    final id = scope.resolve(a.fields['field_id'] as String);
    final f =
        field(await mustDb(dbId), id) ?? (throw StateError('Field not found'));
    final name = _mustName(a.fields['name']);
    await gw.renameField(dbId, id, name);
    return UndoRecord(
      type: type,
      data: {
        'database_id': dbId,
        'field_id': id,
        'before': f.name,
        'after': name,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final dbId = r.data['database_id'] as String;
    final (s, stop) = await undoDb(dbId);
    if (stop != null) return stop;
    final f = field(s!, r.data['field_id'] as String);
    if (f == null) return UndoOutcome.skippedGone;
    if (f.name != r.data['after']) return UndoOutcome.skippedChanged;
    await gw.renameField(dbId, f.id, r.data['before'] as String);
    return UndoOutcome.reverted;
  }
}

/// A type-option write: never selects the option in any row.
class _OptionAdd extends _Base {
  _OptionAdd(super.gw);

  @override
  String get type => 'option.add';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final bad = super.validate(a, scope);
    if (bad != null) return bad;
    final f = _field(scope, a.fields['database_id'], a.fields['field_id']);
    if (f == null) return 'Unknown field_id';
    final name = a.fields['name'];
    final err = _line(name, 'Name');
    if (err != null) return err;
    if ((name as String).contains(',')) return 'Option names have no commas';
    if (f.isEmpty) return null;
    if (!_isSelect(_typeOf(f['type'])) || f['writable'] != true) {
      return 'Not a select field';
    }
    final taken = [for (final o in f['options'] as List? ?? []) o['name']];
    return taken.any((n) => '$n'.toLowerCase() == name.trim().toLowerCase())
        ? 'Option exists'
        : null;
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Add option ${a.fields['name']} to '
            '${labels[a.fields['field_id']] ?? ''}',
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final dbId = db(a, scope);
    final id = scope.resolve(a.fields['field_id'] as String);
    final f = field(await mustDb(dbId), id);
    if (f == null || !_isSelect(f.type)) {
      throw StateError('Not a select field');
    }
    final name = _mustName(a.fields['name'], noComma: true);
    if (f.options.any((o) => o.name.toLowerCase() == name.toLowerCase())) {
      throw StateError('Option $name exists');
    }
    final option = await gw.addOption(dbId, id, name);
    return UndoRecord(
      type: type,
      data: {'database_id': dbId, 'field_id': id, 'option_id': option},
    );
  }

  /// Only while no row uses it.
  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final dbId = r.data['database_id'] as String;
    final (s, stop) = await undoDb(dbId, _allRows);
    if (stop != null) return stop;
    final f = field(s!, r.data['field_id'] as String);
    final o = f?.options.where((o) => o.id == r.data['option_id']).firstOrNull;
    if (f == null || o == null) return UndoOutcome.skippedGone;
    if (s.rows.any(
      (row) => selectNames(f.type, row.cells[f.id] ?? '').contains(o.name),
    )) {
      return UndoOutcome.skippedChanged;
    }
    await gw.removeOption(dbId, f.id, o.id);
    return UndoOutcome.reverted;
  }
}

/// Up to 3 [mentionedIds] that are grids, boards or calendars: fields (with
/// select options) and rows (non-empty cells as text, cut to [_cellCap];
/// a cut cell is read-only as `<row>#<field>`).
Future<ContextPart> databaseContext(
  DatabaseGateway gw,
  List<String> mentionedIds,
) async {
  final all = {for (final d in await gw.databases()) d.id};
  final json = <Map<String, dynamic>>[];
  final labels = <String, String>{};
  final ids = <String>{};
  final readOnly = <String>{};
  final items = <String, Map<String, dynamic>>{};
  for (final id in mentionedIds.where(all.contains).toSet().take(3)) {
    final s = await gw.snapshot(id);
    if (s == null) continue;
    final primary = s.fields.firstOrNull?.id;
    ids.add(id);
    labels[id] = s.name;
    if (s.isLocked) readOnly.add(id);
    if (primary != null) labels['$id#primary'] = primary;
    final fields = [
      for (final f in s.fields)
        {
          'id': f.id,
          'name': f.name,
          'type': _typeName(f.type),
          'writable': f.writable,
          if (f.options.isNotEmpty)
            'options': [
              for (final o in f.options) {'id': o.id, 'name': o.name},
            ],
        },
    ];
    for (final f in fields) {
      final fid = f['id'] as String;
      ids.add(fid);
      labels[fid] = f['name'] as String;
      if (f['writable'] != true) readOnly.add(fid);
      items[fid] = {...f, 'database_id': id}..remove('id');
    }
    final rows = <Map<String, dynamic>>[];
    for (final r in s.rows) {
      final cells = {
        for (final e in r.cells.entries)
          if (e.value.isNotEmpty)
            e.key: e.value.length > _cellCap
                ? e.value.substring(0, _cellCap)
                : e.value,
      };
      for (final e in r.cells.entries) {
        if (e.value.length > _cellCap) readOnly.add('${r.id}#${e.key}');
      }
      ids.add(r.id);
      final title = cells[primary] ?? '';
      labels[r.id] = title.isEmpty ? 'Untitled row' : title;
      for (final e in cells.entries) {
        labels['${r.id}#${e.key}'] = e.value;
      }
      items[r.id] = {'database_id': id, 'cells': cells};
      rows.add({'id': r.id, 'cells': cells});
    }
    json.add({
      'id': id,
      'name': s.name,
      'layout':
          _layouts.entries.where((e) => e.value == s.layout).firstOrNull?.key ??
              'grid',
      'fields': fields,
      'rows': rows,
    });
  }
  return ContextPart(
    json: {'databases': json},
    labels: labels,
    ids: ids,
    readOnlyIds: readOnly,
    items: items,
  );
}
