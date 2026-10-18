import 'package:appflowy/features/assistant/gateways/space.dart';
import 'package:appflowy/plugins/database/application/cell/cell_controller.dart';
import 'package:appflowy/plugins/database/application/field/field_info.dart';
import 'package:appflowy/plugins/database/application/row/row_service.dart';
import 'package:appflowy/plugins/database/domain/cell_service.dart';
import 'package:appflowy/plugins/database/domain/database_view_service.dart';
import 'package:appflowy/plugins/database/domain/date_cell_service.dart';
import 'package:appflowy/plugins/database/domain/field_service.dart';
import 'package:appflowy/workspace/application/view/view_service.dart';
import 'package:appflowy_backend/dispatch/dispatch.dart';
import 'package:appflowy_backend/protobuf/flowy-database2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';

/// One entry of the "My Week" calendar. For all-day entries start == end ==
/// that date at 00:00.
class CalendarEntry {
  const CalendarEntry({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    required this.allDay,
    this.isRange = false,
  });

  final String id;
  final String title;
  final DateTime start;
  final DateTime end;
  final bool allDay;

  /// The date cell's own range flag (a multi-day all-day entry has it).
  final bool isRange;
}

const myWeekName = 'My Week';

/// Thin wrapper over the existing folder/database services; not unit-tested.
/// Every failed backend call throws its `FlowyError`.
class CalendarGateway {
  /// Oldest Calendar view named 'My Week', or null.
  Future<String?> findMyWeek() async {
    final views = (await ViewBackendService.getAllViews()).getOrThrow().items;
    final mine = views
        .where(
          (v) => v.layout == ViewLayoutPB.Calendar && v.name == myWeekName,
        )
        .toList()
      ..sort((a, b) => a.createTime.compareTo(b.createTime));
    return mine.isEmpty ? null : mine.first.id;
  }

  Future<String> ensureMyWeek() async {
    final found = await findMyWeek();
    if (found != null) return found;
    final view = await ViewBackendService.createView(
      layoutType: ViewLayoutPB.Calendar,
      parentViewId: await currentSpaceId(),
      name: myWeekName,
    );
    return view.getOrThrow().id;
  }

  Future<String> _dateFieldId(String viewId) async {
    final s = await DatabaseViewBackendService(viewId: viewId)
        .getLayoutSetting(DatabaseLayoutPB.Calendar);
    return s.getOrThrow().calendar.fieldId;
  }

  Future<CalendarEntry> _read(
    String viewId,
    String dateFieldId,
    String rowId,
    String title,
  ) async {
    final cell = (await CellBackendService.getCell(
      viewId: viewId,
      cellContext: CellContext(fieldId: dateFieldId, rowId: rowId),
    ))
        .getOrThrow();
    final d = DateCellDataPB.fromBuffer(cell.data);
    final start = DateTime.fromMillisecondsSinceEpoch(
      d.timestamp.toInt() * 1000,
    );
    final end = d.isRange
        ? DateTime.fromMillisecondsSinceEpoch(d.endTimestamp.toInt() * 1000)
        : start;
    return CalendarEntry(
      id: rowId,
      title: title,
      start: start,
      end: end,
      allDay: !d.includeTime,
      isRange: d.isRange,
    );
  }

  /// Entries whose start is in [from, to).
  Future<List<CalendarEntry>> entries(
    String viewId,
    DateTime from,
    DateTime to,
  ) async {
    final events = (await DatabaseEventGetAllCalendarEvents(
      CalendarEventRequestPB.create()..viewId = viewId,
    ).send())
        .getOrThrow()
        .items;
    final out = <CalendarEntry>[];
    for (final e in events) {
      final start =
          DateTime.fromMillisecondsSinceEpoch(e.timestamp.toInt() * 1000);
      if (start.isBefore(from) || !start.isBefore(to)) continue;
      out.add(await _read(viewId, e.dateFieldId, e.rowMeta.id, e.title));
    }
    return out;
  }

  Future<CalendarEntry?> entry(String viewId, String rowId) async {
    final events = (await DatabaseEventGetAllCalendarEvents(
      CalendarEventRequestPB.create()..viewId = viewId,
    ).send())
        .getOrThrow()
        .items;
    for (final e in events) {
      if (e.rowMeta.id == rowId) {
        return _read(viewId, e.dateFieldId, rowId, e.title);
      }
    }
    return null;
  }

  Future<void> _setDate(String viewId, String rowId, CalendarEntry e) async {
    final fieldId = await _dateFieldId(viewId);
    (await DateCellBackendService(
      viewId: viewId,
      fieldId: fieldId,
      rowId: rowId,
    ).update(
      date: e.start,
      endDate: e.end,
      isRange: e.isRange,
      includeTime: !e.allDay,
    ))
        .getOrThrow();
  }

  Future<String> add(String viewId, CalendarEntry e) async {
    final primary = (await FieldBackendService.getPrimaryField(viewId: viewId))
        .getOrThrow();
    final row = (await RowBackendService.createRow(
      viewId: viewId,
      withCells: (b) => b.insertText(FieldInfo.initial(primary), e.title),
    ))
        .getOrThrow();
    try {
      await _setDate(viewId, row.id, e);
    } catch (_) {
      await RowBackendService.deleteRows(viewId, [row.id]);
      rethrow;
    }
    return row.id;
  }

  /// Writes only what changed; if the date write fails after the title was
  /// written, the title is put back before rethrowing.
  Future<void> update(String viewId, String rowId, CalendarEntry e) async {
    final old = await entry(viewId, rowId) ?? (throw StateError('Gone'));
    final primary = (await FieldBackendService.getPrimaryField(viewId: viewId))
        .getOrThrow();
    Future<void> setTitle(String t) async =>
        (await CellBackendService.updateCell(
          viewId: viewId,
          cellContext: CellContext(fieldId: primary.id, rowId: rowId),
          data: t,
        ))
            .getOrThrow();
    final titleChanged = old.title != e.title;
    final dateChanged = old.start != e.start ||
        old.end != e.end ||
        old.allDay != e.allDay ||
        old.isRange != e.isRange;
    if (titleChanged) await setTitle(e.title);
    if (!dateChanged) return;
    try {
      await _setDate(viewId, rowId, e);
    } catch (_) {
      if (titleChanged) {
        try {
          await setTitle(old.title);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> remove(String viewId, String rowId) async =>
      (await RowBackendService.deleteRows(viewId, [rowId])).getOrThrow();
}
