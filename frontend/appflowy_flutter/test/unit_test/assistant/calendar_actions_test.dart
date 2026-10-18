import 'package:appflowy/features/assistant/actions/calendar_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/calendar_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGateway extends Mock implements CalendarGateway {}

// Mon 2026-10-19.
final week = DateTime(2026, 10, 19);

CalendarEntry entry(
  String id,
  String title,
  DateTime s,
  DateTime e, {
  bool allDay = false,
  bool? isRange,
}) =>
    CalendarEntry(
      id: id,
      title: title,
      start: s,
      end: e,
      allDay: allDay,
      isRange: isRange ?? !allDay,
    );

final dentist = entry(
  'r1',
  'Dentist',
  DateTime(2026, 10, 20, 16),
  DateTime(2026, 10, 20, 17),
);

AssistAction act(String type, Map<String, dynamic> f) =>
    AssistAction(type: type, fields: {'type': type, ...f});

void main() {
  late _MockGateway gw;
  late Map<String, ActionHandler> h;
  late ValidationScope scope;

  setUpAll(() => registerFallbackValue(dentist));
  setUp(() {
    gw = _MockGateway();
    h = {for (final x in calendarHandlers(gw)) x.type: x};
    scope = ValidationScope(knownIds: {'r1'}, weekStart: week);
  });

  test('add: ensures My Week, adds, records new id', () async {
    when(() => gw.ensureMyWeek()).thenAnswer((_) async => 'v1');
    when(() => gw.add('v1', any())).thenAnswer((_) async => 'r9');
    final r = await h['calendar.add']!.apply(
      act('calendar.add', {
        'title': 'Gym',
        'date': '2026-10-21',
        'start': '18:00',
        'end': '19:00',
        'all_day': false,
      }),
      ApplyScope({}),
    );
    verify(() => gw.ensureMyWeek()).called(1);
    final e = verify(() => gw.add('v1', captureAny())).captured.single
        as CalendarEntry;
    expect(e.start, DateTime(2026, 10, 21, 18));
    expect(r.type, 'calendar.add');
    expect(r.data['entry_id'], 'r9');
  });

  test('add all day stores midnight', () async {
    when(() => gw.ensureMyWeek()).thenAnswer((_) async => 'v1');
    when(() => gw.add('v1', any())).thenAnswer((_) async => 'r9');
    await h['calendar.add']!.apply(
      act(
        'calendar.add',
        {'title': 'Trip', 'date': '2026-10-21', 'all_day': true},
      ),
      ApplyScope({}),
    );
    final e = verify(() => gw.add('v1', captureAny())).captured.single
        as CalendarEntry;
    expect(e.allDay, true);
    expect(e.start, DateTime(2026, 10, 21));
    expect(e.end, DateTime(2026, 10, 21));
  });

  test('validate rules', () {
    String? v(String t, Map<String, dynamic> f) =>
        h[t]!.validate(act(t, f), scope);
    final ok = {
      'title': 'A',
      'date': '2026-10-25',
      'start': '09:00',
      'end': '10:00',
      'all_day': false,
    };
    expect(v('calendar.add', ok), isNull);
    expect(v('calendar.add', {...ok, 'date': '2026-10-26'}), isNotNull);
    expect(v('calendar.add', {...ok, 'start': '10:00'}), isNotNull);
    expect(v('calendar.add', {...ok, 'start': '9am'}), isNotNull);
    expect(v('calendar.add', {...ok, 'title': ''}), isNotNull);
    expect(v('calendar.add', {...ok, 'title': 'a\nb'}), isNotNull);
    expect(v('calendar.add', {...ok, 'title': 'x' * 121}), isNotNull);
    expect(v('calendar.add', {...ok, 'all_day': true, 'start': null}), isNull);
    expect(v('calendar.update', {'entry_id': 'zz', 'title': 'A'}), isNotNull);
    expect(v('calendar.update', {'entry_id': 'r1', 'title': 'A'}), isNull);
    expect(v('calendar.remove', {'entry_id': 'r1'}), isNull);
    expect(v('calendar.remove', {'entry_id': 'zz'}), isNotNull);
  });

  test('previews', () {
    final labels = {'r1': 'Dentist · Tue 16:00–17:00'};
    final u = h['calendar.update']!.describe(
      act('calendar.update', {
        'entry_id': 'r1',
        'date': '2026-10-21',
        'start': '17:00',
        'end': '18:00',
      }),
      labels,
    );
    expect(u.text, 'Change: Dentist');
    expect(u.before, 'Dentist · Tue 16:00–17:00');
    expect(u.after, 'Dentist · Wed 17:00–18:00');
    expect(u.editable, ['date', 'start', 'end']);
    final r = h['calendar.remove']!
        .describe(act('calendar.remove', {'entry_id': 'r1'}), labels);
    expect(r.text, 'Remove: Dentist · Tue 16:00–17:00');
    expect(r.destructive, true);
    expect(r.editable, isEmpty);
    final a = h['calendar.add']!.describe(
      act('calendar.add', {
        'title': 'Gym',
        'date': '2026-10-21',
        'start': '18:00',
        'end': '19:00',
      }),
      {},
    );
    expect(a.text, 'Add: Gym · Wed 18:00–19:00');
    expect(a.editable, ['title', 'date', 'start', 'end']);
  });

  test('title-only update keeps a multi-day all-day span', () async {
    final trip = entry(
      'r5',
      'Trip',
      DateTime(2026, 10, 21),
      DateTime(2026, 10, 23),
      allDay: true,
      isRange: true,
    );
    when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
    when(() => gw.entry('v1', 'r5')).thenAnswer((_) async => trip);
    when(() => gw.update('v1', 'r5', any())).thenAnswer((_) async {});
    await h['calendar.update']!.apply(
      act('calendar.update', {'entry_id': 'r5', 'title': 'Holiday'}),
      ApplyScope({}),
    );
    final e = verify(() => gw.update('v1', 'r5', captureAny())).captured.single
        as CalendarEntry;
    expect(e.title, 'Holiday');
    expect(e.start, trip.start);
    expect(e.end, trip.end);
    expect(e.isRange, true);
    expect(e.allDay, true);
  });

  test('validate: all_day must be bool, titles trimmed, no CR', () {
    String? v(Map<String, dynamic> f) =>
        h['calendar.update']!.validate(act('calendar.update', f), scope);
    expect(v({'entry_id': 'r1', 'all_day': 'yes'}), isNotNull);
    expect(v({'entry_id': 'r1', 'title': 'a\rb'}), isNotNull);
    expect(v({'entry_id': 'r1', 'title': '  ${'x' * 120}  '}), isNull);
    expect(v({'entry_id': 'r1', 'title': '   '}), isNotNull);
  });

  group('update', () {
    final moved = entry(
      'r1',
      'Dentist',
      DateTime(2026, 10, 21, 17),
      DateTime(2026, 10, 21, 18),
    );
    Future<UndoRecord> doUpdate() {
      when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
      when(() => gw.update('v1', 'r1', any())).thenAnswer((_) async {});
      return h['calendar.update']!.apply(
        act('calendar.update', {
          'entry_id': 'r1',
          'date': '2026-10-21',
          'start': '17:00',
          'end': '18:00',
        }),
        ApplyScope({}),
      );
    }

    test('apply merges and records before/after', () async {
      when(() => gw.entry(any(), 'r1')).thenAnswer((_) async => dentist);
      final r = await doUpdate();
      final e = verify(() => gw.update('v1', 'r1', captureAny()))
          .captured
          .single as CalendarEntry;
      expect(e.title, 'Dentist');
      expect(e.start, DateTime(2026, 10, 21, 17));
      expect(r.type, 'calendar.update');
    });

    test('apply throws when entry gone', () async {
      when(() => gw.entry(any(), 'r1')).thenAnswer((_) async => null);
      expect(doUpdate(), throwsA(anything));
    });

    test('undo restores only if unchanged since', () async {
      when(() => gw.entry(any(), 'r1')).thenAnswer((_) async => dentist);
      final r = await doUpdate();
      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => moved);
      expect(await h['calendar.update']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.update('v1', 'r1', any())).called(2);

      clearInteractions(gw);
      when(() => gw.entry('v1', 'r1')).thenAnswer(
        (_) async => entry('r1', 'Dentist!', moved.start, moved.end),
      );
      expect(await h['calendar.update']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.update(any(), any(), any()));

      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => null);
      expect(await h['calendar.update']!.undo(r), UndoOutcome.skippedGone);
    });
  });

  group('remove', () {
    test('undo re-adds if absent, skips if present', () async {
      when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => dentist);
      when(() => gw.remove('v1', 'r1')).thenAnswer((_) async {});
      final r = await h['calendar.remove']!
          .apply(act('calendar.remove', {'entry_id': 'r1'}), ApplyScope({}));
      expect(r.type, 'calendar.remove');
      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => null);
      when(() => gw.add('v1', any())).thenAnswer((_) async => 'r2');
      when(() => gw.entries('v1', any(), any())).thenAnswer((_) async => []);
      expect(await h['calendar.remove']!.undo(r), UndoOutcome.reverted);
      final e = verify(() => gw.add('v1', captureAny())).captured.single
          as CalendarEntry;
      expect(e.title, 'Dentist');
      expect(e.start, dentist.start);
      // Second undo: a twin now exists under the new id -> no duplicate.
      when(() => gw.entries('v1', any(), any()))
          .thenAnswer((_) async => [dentist]);
      clearInteractions(gw);
      expect(await h['calendar.remove']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.add(any(), any()));
    });

    test('undo twice: one add, both reverted; twin does not block', () async {
      when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => dentist);
      when(() => gw.remove('v1', 'r1')).thenAnswer((_) async {});
      final r = await h['calendar.remove']!
          .apply(act('calendar.remove', {'entry_id': 'r1'}), ApplyScope({}));
      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => null);
      when(() => gw.add('v1', any())).thenAnswer((_) async => 'r2');
      // An identical entry already exists under another id: still restores.
      when(() => gw.entries('v1', any(), any()))
          .thenAnswer((_) async => [dentist]);
      expect(await h['calendar.remove']!.undo(r), UndoOutcome.reverted);
      expect(r.data['restored_id'], 'r2');
      expect(await h['calendar.remove']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.add('v1', any())).called(1);
    });

    test('multi-day all-day entry is re-added with same span', () async {
      final trip = entry(
        'r5',
        'Trip',
        DateTime(2026, 10, 21),
        DateTime(2026, 10, 23),
        allDay: true,
        isRange: true,
      );
      when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
      when(() => gw.entry('v1', 'r5')).thenAnswer((_) async => trip);
      when(() => gw.remove('v1', 'r5')).thenAnswer((_) async {});
      final r = await h['calendar.remove']!
          .apply(act('calendar.remove', {'entry_id': 'r5'}), ApplyScope({}));
      when(() => gw.entry('v1', 'r5')).thenAnswer((_) async => null);
      when(() => gw.add('v1', any())).thenAnswer((_) async => 'r6');
      await h['calendar.remove']!.undo(r);
      final e = verify(() => gw.add('v1', captureAny())).captured.single
          as CalendarEntry;
      expect(e.start, trip.start);
      expect(e.end, trip.end);
      expect(e.isRange, true);
      expect(e.allDay, true);
    });

    test('apply throws when entry gone', () async {
      when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
      when(() => gw.entry('v1', 'r1')).thenAnswer((_) async => null);
      expect(
        h['calendar.remove']!
            .apply(act('calendar.remove', {'entry_id': 'r1'}), ApplyScope({})),
        throwsA(anything),
      );
    });
  });

  test('undo add: removes if unchanged, idempotent when gone', () async {
    when(() => gw.ensureMyWeek()).thenAnswer((_) async => 'v1');
    when(() => gw.add('v1', any())).thenAnswer((_) async => 'r9');
    final r = await h['calendar.add']!.apply(
      act('calendar.add', {
        'title': 'Gym',
        'date': '2026-10-21',
        'start': '18:00',
        'end': '19:00',
      }),
      ApplyScope({}),
    );
    final mine = entry(
      'r9',
      'Gym',
      DateTime(2026, 10, 21, 18),
      DateTime(2026, 10, 21, 19),
    );
    when(() => gw.entry('v1', 'r9')).thenAnswer((_) async => mine);
    when(() => gw.remove('v1', 'r9')).thenAnswer((_) async {});
    expect(await h['calendar.add']!.undo(r), UndoOutcome.reverted);
    when(() => gw.entry('v1', 'r9')).thenAnswer((_) async => null);
    expect(await h['calendar.add']!.undo(r), UndoOutcome.skippedGone);
    when(() => gw.entry('v1', 'r9'))
        .thenAnswer((_) async => entry('r9', 'Gym2', mine.start, mine.end));
    expect(await h['calendar.add']!.undo(r), UndoOutcome.skippedChanged);
  });

  group('calendarContext', () {
    test('never creates My Week; no view -> empty', () async {
      when(() => gw.findMyWeek()).thenAnswer((_) async => null);
      final c = await calendarContext(gw, week);
      expect(c.json, {'id': null, 'entries': <dynamic>[]});
      verifyNever(() => gw.ensureMyWeek());
    });

    test('builds json, labels, ids', () async {
      when(() => gw.findMyWeek()).thenAnswer((_) async => 'v1');
      when(() => gw.entries('v1', any(), any())).thenAnswer(
        (_) async => [
          dentist,
          entry(
            'r2',
            'Trip',
            DateTime(2026, 10, 22),
            DateTime(2026, 10, 22),
            allDay: true,
          ),
        ],
      );
      final c = await calendarContext(gw, week);
      final range =
          verify(() => gw.entries('v1', captureAny(), captureAny())).captured;
      expect(range[0], DateTime(2026, 10, 12));
      expect(range[1], DateTime(2026, 10, 26));
      expect(c.ids, {'r1', 'r2'});
      expect(c.labels['r1'], 'Dentist · Tue 16:00–17:00');
      expect(c.labels['r2'], 'Trip · Thu (all day)');
      expect(c.json['id'], 'v1');
      expect((c.json['entries'] as List).first, {
        'id': 'r1',
        'title': 'Dentist',
        'date': '2026-10-20',
        'start': '16:00',
        'end': '17:00',
        'all_day': false,
        'is_range': true,
      });
      expect((c.json['entries'] as List).last['start'], isNull);
    });
  });
}
