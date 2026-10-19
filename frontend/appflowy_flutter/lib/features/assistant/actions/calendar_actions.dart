import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/calendar_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';

const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
final _timeRe = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');
final _dateRe = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _labelRe = RegExp(
  r'^(.*) · (\w{3}) (?:(\d\d:\d\d)(?:–(\d\d:\d\d))?|\(all day\))$',
);

String _two(int n) => n.toString().padLeft(2, '0');
String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
String _ymd(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// No [e]: a single point in time.
String _slot(String title, String day, bool allDay, String? s, String? e) =>
    allDay
        ? '$title · $day (all day)'
        : e == null
            ? '$title · $day $s'
            : '$title · $day $s–$e';

/// The end time, null for all-day entries and single points.
String? _endHm(CalendarEntry e) => e.allDay || !e.isRange ? null : _hm(e.end);

String _label(CalendarEntry e) => _slot(
      e.title,
      _days[e.start.weekday - 1],
      e.allDay,
      _hm(e.start),
      _endHm(e),
    );

DateTime? _date(Object? v) {
  final m = v is String ? _dateRe.firstMatch(v) : null;
  if (m == null) return null;
  final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  return _ymd(d) == v ? d : null;
}

DateTime _at(DateTime day, String hm) => DateTime(
      day.year,
      day.month,
      day.day,
      int.parse(hm.substring(0, 2)),
      int.parse(hm.substring(3)),
    );

bool _same(CalendarEntry? e, Map<String, dynamic> m) =>
    e != null &&
    e.title == m['title'] &&
    e.allDay == m['all_day'] &&
    e.isRange == (m['is_range'] as bool? ?? !e.allDay) &&
    _minute(e.start) == m['start'] &&
    _minute(e.end) == m['end'];

String _minute(DateTime d) =>
    DateTime(d.year, d.month, d.day, d.hour, d.minute).toIso8601String();

Map<String, dynamic> _snap(CalendarEntry e) => {
      'title': e.title,
      'start': _minute(e.start),
      'end': _minute(e.end),
      'all_day': e.allDay,
      'is_range': e.isRange,
    };

CalendarEntry _fromSnap(String id, Map<String, dynamic> m) => CalendarEntry(
      id: id,
      title: m['title'] as String,
      start: DateTime.parse(m['start'] as String),
      end: DateTime.parse(m['end'] as String),
      allDay: m['all_day'] as bool,
      isRange: m['is_range'] as bool? ?? !(m['all_day'] as bool),
    );

List<ActionHandler> calendarHandlers(CalendarGateway gw) =>
    [_Add(gw), _Update(gw), _Remove(gw)];

abstract class _Base implements ActionHandler {
  _Base(this.gw);
  final CalendarGateway gw;

  @override
  AssistStage get stage => AssistStage.schedule;

  /// Checks the optional fields shared by add and update; the week only
  /// when [weekStart] is given (apply re-checks the user's edits without it).
  String? checkFields(Map<String, dynamic> f, [DateTime? weekStart]) {
    if (f.containsKey('title')) {
      final t = f['title'];
      if (t is! String || t.trim().isEmpty) return 'Title is empty';
      if (t.trim().length > 120 || t.contains(RegExp(r'[\r\n]'))) {
        return 'Title is too long';
      }
    }
    if (f['all_day'] != null && f['all_day'] is! bool) return 'Bad all_day';
    if (f['date'] != null) {
      final d = _date(f['date']);
      if (d == null) return 'Bad date';
      if (weekStart != null) {
        final w = DateTime(weekStart.year, weekStart.month, weekStart.day);
        if (d.isBefore(w) || d.isAfter(DateTime(w.year, w.month, w.day + 6))) {
          return 'Date is outside this week';
        }
      }
    }
    for (final k in ['start', 'end']) {
      final v = f[k];
      if (v != null && (v is! String || !_timeRe.hasMatch(v))) {
        return 'Bad $k time';
      }
    }
    final s = f['start'], e = f['end'];
    if (f['all_day'] != true &&
        s is String &&
        e is String &&
        s.compareTo(e) >= 0) {
      return 'Start must be before end';
    }
    return null;
  }

  String? checkId(AssistAction a, ValidationScope scope) {
    final id = a.fields['entry_id'];
    if (!scope.knownIds.contains(id)) return 'Unknown calendar entry';
    return scope.readOnlyIds.contains(id) ? 'My Week is locked' : null;
  }

  Future<String> view() async =>
      await gw.findMyWeek() ?? (throw StateError('My Week not found'));

  /// [viewId], or throws when My Week is locked (a lock may be set after the
  /// proposal). Call before any write.
  Future<String> writable(String viewId) async {
    if (await gw.isLocked(viewId)) throw StateError('My Week is locked');
    return viewId;
  }
}

class _Add extends _Base {
  _Add(super.gw);

  @override
  String get type => 'calendar.add';

  /// No end: a single point in time.
  String? _check(Map<String, dynamic> f, [DateTime? weekStart]) {
    if (f['title'] == null) return 'Title is empty';
    if (f['date'] == null) return 'Bad date';
    if (f['all_day'] != true && f['start'] == null) return 'Start is required';
    return checkFields(f, weekStart);
  }

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      _check(a.fields, scope.weekStart);

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final f = a.fields;
    final d = _date(f['date']);
    return ActionPreview(
      text:
          'Add: ${_slot(f['title'] as String, d == null ? '' : _days[d.weekday - 1], f['all_day'] == true, f['start'] as String?, f['end'] as String?)}',
      editable: const ['title', 'date', 'start', 'end'],
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final f = a.fields;
    mustBeValid(_check(f));
    final day = _date(f['date'])!;
    final allDay = f['all_day'] == true;
    final end = allDay ? null : f['end'] as String?;
    final e = CalendarEntry(
      id: '',
      title: (f['title'] as String).trim(),
      start: allDay ? day : _at(day, f['start'] as String),
      end: allDay ? day : _at(day, end ?? f['start'] as String),
      allDay: allDay,
      isRange: end != null,
    );
    final viewId = await writable(await gw.ensureMyWeek());
    final id = await gw.add(viewId, e);
    return UndoRecord(
      type: type,
      data: {'view_id': viewId, 'entry_id': id, 'after': _snap(e)},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final viewId = r.data['view_id'] as String;
    final id = r.data['entry_id'] as String;
    final cur = await gw.entry(viewId, id);
    if (cur == null) return UndoOutcome.skippedGone;
    if (!_same(cur, Map<String, dynamic>.from(r.data['after'] as Map)) ||
        await gw.isLocked(viewId)) {
      return UndoOutcome.skippedChanged;
    }
    await gw.remove(viewId, id);
    return UndoOutcome.reverted;
  }
}

class _Update extends _Base {
  _Update(super.gw);

  @override
  String get type => 'calendar.update';

  /// Editable in the preview (all_day is a bool, not text).
  static const _keys = ['title', 'date', 'start', 'end'];

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      checkId(a, scope) ?? checkFields(a.fields, scope.weekStart);

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final f = a.fields;
    final before = labels[f['entry_id']] ?? '';
    final m = _labelRe.firstMatch(before);
    final title = (f['title'] as String?) ?? m?[1] ?? '';
    final d = _date(f['date']);
    final allDay = (f['all_day'] as bool?) ?? (m != null && m[3] == null);
    return ActionPreview(
      text: 'Change: $title',
      before: before,
      after: _slot(
        title,
        d != null ? _days[d.weekday - 1] : m?[2] ?? '',
        allDay,
        (f['start'] as String?) ?? m?[3],
        (f['end'] as String?) ?? m?[4],
      ),
      editable: [
        for (final k in _keys)
          if (f.containsKey(k)) k,
      ],
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final f = a.fields;
    mustBeValid(checkFields(f));
    final viewId = await writable(await view());
    final id = f['entry_id'] as String;
    final cur =
        await gw.entry(viewId, id) ?? (throw StateError('Entry not found'));
    final title = ((f['title'] as String?) ?? cur.title).trim();
    final allDay = (f['all_day'] as bool?) ?? cur.allDay;
    final curDay = DateTime(cur.start.year, cur.start.month, cur.start.day);
    final day = _date(f['date']) ?? curDay;
    final CalendarEntry next;
    if (allDay) {
      // Keep a multi-day span: shift it, don't collapse it.
      final endDay = DateTime(cur.end.year, cur.end.month, cur.end.day);
      final span = cur.allDay ? endDay.difference(curDay).inDays : 0;
      next = CalendarEntry(
        id: id,
        title: title,
        start: day,
        end: DateTime(day.year, day.month, day.day + span),
        allDay: true,
        isRange: cur.allDay && cur.isRange,
      );
    } else {
      final s = (f['start'] as String?) ?? (cur.allDay ? null : _hm(cur.start));
      // No end given: a range keeps its end, a single point stays one.
      final e = (f['end'] as String?) ?? _endHm(cur);
      if (s == null) throw StateError('Start is required');
      if (e != null && s.compareTo(e) >= 0) {
        throw StateError('Start must be before end');
      }
      next = CalendarEntry(
        id: id,
        title: title,
        start: _at(day, s),
        end: _at(day, e ?? s),
        allDay: false,
        isRange: e != null,
      );
    }
    await gw.update(viewId, id, next);
    return UndoRecord(
      type: type,
      data: {
        'view_id': viewId,
        'entry_id': id,
        'before': _snap(cur),
        'after': _snap(next),
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final viewId = r.data['view_id'] as String;
    final id = r.data['entry_id'] as String;
    final cur = await gw.entry(viewId, id);
    if (cur == null) return UndoOutcome.skippedGone;
    if (!_same(cur, Map<String, dynamic>.from(r.data['after'] as Map)) ||
        await gw.isLocked(viewId)) {
      return UndoOutcome.skippedChanged;
    }
    await gw.update(
      viewId,
      id,
      _fromSnap(id, Map<String, dynamic>.from(r.data['before'] as Map)),
    );
    return UndoOutcome.reverted;
  }
}

/// Known limit: undoing a remove re-adds the entry under a NEW id, so other
/// records in the same batch that hold the old entry id will see skippedGone.
class _Remove extends _Base {
  _Remove(super.gw);

  @override
  String get type => 'calendar.remove';

  @override
  String? validate(AssistAction a, ValidationScope scope) => checkId(a, scope);

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Remove: ${labels[a.fields['entry_id']] ?? ''}',
        destructive: true,
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final viewId = await writable(await view());
    final id = a.fields['entry_id'] as String;
    final cur =
        await gw.entry(viewId, id) ?? (throw StateError('Entry not found'));
    await gw.remove(viewId, id);
    return UndoRecord(
      type: type,
      data: {'view_id': viewId, 'entry_id': id, 'before': _snap(cur)},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final viewId = r.data['view_id'] as String;
    final id = r.data['entry_id'] as String;
    // Idempotent: a repeated undo must not re-add a second copy.
    if (r.data['restored_id'] != null) return UndoOutcome.reverted;
    if (await gw.entry(viewId, id) != null || await gw.isLocked(viewId)) {
      return UndoOutcome.skippedChanged;
    }
    final before = Map<String, dynamic>.from(r.data['before'] as Map);
    final newId = await gw.add(viewId, _fromSnap(id, before));
    // The service persists the record after undo, so this survives a re-run.
    r.data['restored_id'] = newId;
    return UndoOutcome.reverted;
  }
}

/// This week + last week of "My Week" for the AI. Never creates the view.
/// Every entry is read-only while My Week is locked.
Future<ContextPart> calendarContext(
  CalendarGateway gw,
  DateTime weekStart,
) async {
  final viewId = await gw.findMyWeek();
  final locked = viewId != null && await gw.isLocked(viewId);
  final list = viewId == null
      ? <CalendarEntry>[]
      : await gw.entries(
          viewId,
          DateTime(weekStart.year, weekStart.month, weekStart.day - 7),
          DateTime(weekStart.year, weekStart.month, weekStart.day + 7),
        );
  return ContextPart(
    json: {
      'id': viewId,
      'entries': [
        for (final e in list)
          {
            'id': e.id,
            'title': e.title,
            'date': _ymd(e.start),
            'start': e.allDay ? null : _hm(e.start),
            'end': _endHm(e),
            'all_day': e.allDay,
            'is_range': e.isRange,
          },
      ],
    },
    labels: {for (final e in list) e.id: _label(e)},
    ids: {for (final e in list) e.id},
    readOnlyIds: {
      if (locked)
        for (final e in list) e.id,
    },
  );
}
