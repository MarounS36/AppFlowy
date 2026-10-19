import 'dart:async';

import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/actions/board_actions.dart';
import 'package:appflowy/features/assistant/actions/calendar_actions.dart';
import 'package:appflowy/features/assistant/data/assist_api.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/data/assistant_store.dart';
import 'package:appflowy/features/assistant/gateways/board_gateway.dart';
import 'package:appflowy/features/assistant/gateways/calendar_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_engine.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy_backend/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockCalendar extends Mock implements CalendarGateway {}

class _MockBoards extends Mock implements BoardGateway {}

class _MockApi extends Mock implements AssistApi {}

/// The next [failSets] writes throw.
class _FlakyKv extends DartKeyValue {
  int failSets = 0;

  @override
  Future<void> set(String key, String value) {
    if (failSets > 0) {
      failSets--;
      throw Exception('disk full');
    }
    return super.set(key, value);
  }
}

final calls = <String>[];

/// `ref` must be a context id; `destructive` marks the preview; only `title`
/// is editable; an action whose `n` is in [failing] throws once.
class _Fake implements ActionHandler {
  _Fake(this.type, [this.stage = AssistStage.schedule]);

  @override
  final String type;
  @override
  final AssistStage stage;
  Future<void> Function()? beforeApply;
  final failing = <int>{};

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final ref = a.fields['ref'];
    return ref == null || scope.knownIds.contains(ref) ? null : 'unknown';
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: type,
        destructive: a.fields['destructive'] == true,
        editable: const ['title'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    await beforeApply?.call();
    final n = a.fields['n'] as int;
    final title = a.fields['title'];
    calls.add(title == null ? 'apply $n' : 'apply $n $title');
    if (failing.remove(n)) throw StateError('boom $n');
    return UndoRecord(type: type, data: {'n': n});
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    calls.add('undo ${r.data['n']}');
    r.data['undone'] = true;
    return UndoOutcome.reverted;
  }
}

AssistAction act(
  int n, {
  String type = 'cal.x',
  String? ref,
  String? temp,
  bool destructive = false,
}) =>
    AssistAction(
      type: type,
      fields: {
        'type': type,
        'n': n,
        if (ref != null) 'ref': ref,
        if (temp != null) 'temp_id': temp,
        if (destructive) 'destructive': true,
      },
    );

Proposal proposal(
  List<AssistAction> actions, {
  Set<int>? ticked,
  Map<int, Map<String, dynamic>>? edits,
}) =>
    Proposal(
      id: 'p1',
      actions: actions,
      note: '',
      weekStart: '2026-10-19',
      labels: const {},
      ticked: ticked,
      edits: edits,
    );

Matcher throwsKind(OrganizeErrorKind kind) => throwsA(
      isA<OrganizeApiException>().having((e) => e.kind, 'kind', kind),
    );

void main() {
  late _MockCalendar calendar;
  late _MockBoards boards;
  late _MockApi api;
  late _FlakyKv kv;
  late _Fake cal;
  late _Fake page;
  late List<String> tokens;
  late List<Map<String, dynamic>> bodies;

  AssistantStore store() => AssistantStore(kv: kv, userId: 'u1');

  AssistantService service([ActionEngine? engine]) => AssistantService(
        store: store(),
        api: api,
        engine: engine ?? ActionEngine([cal, page]),
        calendar: calendar,
        boards: boards,
        accessToken: () async =>
            tokens.length > 1 ? tokens.removeAt(0) : tokens.first,
        now: () => DateTime(2026, 10, 19, 9), // a Monday
      );

  void reply(List<AssistAction> actions, {String note = 'ok'}) => when(
        () => api.send(token: any(named: 'token'), body: any(named: 'body')),
      ).thenAnswer((inv) async {
        bodies.add(inv.namedArguments[#body] as Map<String, dynamic>);
        return AssistReply(note: note, actions: actions);
      });

  Future<AssistantService> consented([
    AssistStage stage = AssistStage.schedule,
  ]) async {
    final s = service();
    await s.setConsentedStage(stage);
    return s;
  }

  Future<void> seed(Proposal p, {List<AppliedProposal>? applied}) =>
      store().save(
        AssistantState(
          consentedStage: AssistStage.schedule,
          proposal: p,
          applied: applied,
        ),
      );

  ActionEngine realEngine() => ActionEngine([
        ...calendarHandlers(calendar),
        ...boardHandlers(boards),
      ]);

  setUpAll(() => registerFallbackValue(DateTime(2026)));

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Log.shared.disableLog = true;
    kv = _FlakyKv();
    calendar = _MockCalendar();
    boards = _MockBoards();
    api = _MockApi();
    cal = _Fake('cal.x');
    page = _Fake('page.x', AssistStage.pages);
    calls.clear();
    bodies = [];
    tokens = ['t1'];
    when(() => calendar.findMyWeek()).thenAnswer((_) async => 'week');
    when(() => calendar.entries(any(), any(), any())).thenAnswer(
      (_) async => [
        CalendarEntry(
          id: 'e1',
          title: 'Gym',
          start: DateTime(2026, 10, 20, 7),
          end: DateTime(2026, 10, 20, 8),
          allDay: false,
        ),
      ],
    );
    when(() => boards.boards()).thenAnswer(
      (_) async => [
        (id: 'b1', name: 'Sprint'),
        (id: 'b2', name: 'Home Reno'),
        (id: 'b3', name: 'Garden'),
      ],
    );
    when(() => boards.board(any())).thenAnswer((_) async => null);
    reply([]);
  });

  group('send', () {
    test('send refused when disabled or not consented', () async {
      final s = service();
      await expectLater(
        s.send('hi', mentionIds: []),
        throwsKind(OrganizeErrorKind.failed),
      );
      await s.setConsentedStage(AssistStage.schedule);
      await s.setEnabled(false);
      await expectLater(
        s.send('hi', mentionIds: []),
        throwsKind(OrganizeErrorKind.failed),
      );
      verifyNever(
        () => api.send(token: any(named: 'token'), body: any(named: 'body')),
      );
      expect((await s.state()).thread, isEmpty);
    });

    test('send posts only allowed action types for the active stage', () async {
      final s = await consented(AssistStage.workspace);
      expect(await s.activeStage(), AssistStage.schedule);

      await s.send('plan next week with Sprint', mentionIds: ['b1', 'page9']);

      final body = bodies.single;
      expect(body['allowed_actions'], ['cal.x']);
      expect(body['messages'], [
        {'role': 'user', 'text': 'plan next week with Sprint'},
      ]);
      expect(body.containsKey('proposal'), isFalse);
      final ctx = body['context'] as Map;
      expect(ctx['week_start'], '2026-10-26');
      expect((ctx['calendar'] as Map)['id'], 'week');
      expect(
        [for (final b in ctx['boards'] as List) (b as Map)['id']],
        ['b1', 'b2', 'b3'],
      );
      verify(() => boards.board('b1')).called(1);
      verifyNever(() => boards.board('page9'));
    });

    test('follow-up sends the current proposal as the user sees it', () async {
      final s = await consented();
      reply([act(0, ref: 'b1'), act(1)], note: 'Added it');
      (await s.send('add gym', mentionIds: []))!
        ..ticked = {0}
        ..edits = {
          0: {'title': 'Gym', 'n': 99},
        };
      await s.send('also Friday', mentionIds: []);

      final body = bodies.last;
      expect(
        body['proposal'],
        [
          {'type': 'cal.x', 'n': 0, 'ref': 'b1', 'title': 'Gym'},
        ],
        reason: 'ticked actions only, with edits to editable keys',
      );
      expect(body['messages'], [
        {'role': 'user', 'text': 'add gym'},
        {'role': 'assistant', 'text': 'Added it'},
        {'role': 'user', 'text': 'also Friday'},
      ]);
    });

    test('real handlers offer board and calendar actions at stage schedule',
        () async {
      final s = service(realEngine());
      await s.setConsentedStage(AssistStage.schedule);
      await s.send('hi', mentionIds: []);
      expect(
        bodies.single['allowed_actions'],
        containsAll(['board.create', 'calendar.add']),
      );
    });

    test('a follow-up details the boards the open proposal touches', () async {
      when(() => boards.board('b1')).thenAnswer(
        (_) async => const BoardSnapshot(
          id: 'b1',
          name: 'Sprint',
          columns: [BoardColumn(id: 'todo', name: 'To do', isDefault: false)],
          cards: [BoardCard(id: 'c1', title: 'Spec', columnId: 'todo')],
          editable: true,
        ),
      );
      AssistAction update(String title) => AssistAction(
            type: 'board.card.update',
            fields: {
              'type': 'board.card.update',
              'board_id': 'b1',
              'card_id': 'c1',
              'title': title,
            },
          );
      await seed(proposal([update('Write spec')]));
      reply([update('Write the spec')]);

      final p = await service(realEngine()).send(
        'make it longer',
        mentionIds: [],
      );

      verify(() => boards.board('b1')).called(1);
      expect(p!.actions.single.fields['title'], 'Write the spec');
    });

    test('a reply that arrives after the proposal was applied is dropped',
        () async {
      await seed(proposal([act(0)]));
      final s = service();
      final started = Completer<void>();
      final gate = Completer<AssistReply>();
      when(
        () => api.send(token: any(named: 'token'), body: any(named: 'body')),
      ).thenAnswer((_) {
        started.complete();
        return gate.future;
      });

      final sending = s.send('also Friday', mentionIds: []);
      await started.future;
      await s.apply();
      gate.complete(AssistReply(note: 'Revised', actions: [act(1)]));

      expect(await sending, isNull);
      final saved = await store().load();
      expect(saved.proposal, isNull);
      expect(saved.thread.last.text, 'Revised');
      expect(calls, ['apply 0']);
    });

    test('sends only the last 10 turns', () async {
      await store().save(
        AssistantState(
          consentedStage: AssistStage.schedule,
          thread: [
            for (var i = 0; i < 10; i++)
              ChatTurn(role: i.isEven ? 'user' : 'assistant', text: 't$i'),
          ],
        ),
      );
      await service().send('new', mentionIds: []);

      final messages = bodies.single['messages'] as List;
      expect(messages, hasLength(10));
      expect(messages.first, {'role': 'assistant', 'text': 't1'});
      expect(messages.last, {'role': 'user', 'text': 'new'});
    });

    test('client re-validation drops actions the server let through', () async {
      final s = await consented();
      reply([
        act(0, ref: 'b1'),
        act(1, ref: 'nope'),
        act(2, type: 'page.x'),
        act(3, type: 'zzz'),
        act(4, ref: 'e1', destructive: true),
      ]);

      final p = (await s.send('move it', mentionIds: []))!;

      expect([for (final a in p.actions) a.fields['n']], [0, 4]);
      expect(p.ticked, {0}, reason: 'destructive actions start unticked');
      expect(p.weekStart, '2026-10-19');
      expect(p.labels['b1'], 'Sprint');
      expect(p.labels['e1'], isNotNull);
      final saved = await store().load();
      expect(saved.proposal!.id, p.id);
      expect(saved.thread.map((t) => t.role), ['user', 'assistant']);
    });

    test('a reply with no valid action clears the proposal, keeps the note',
        () async {
      final s = await consented();
      reply([act(0, ref: 'b1')]);
      await s.send('a', mentionIds: []);
      reply([act(1, ref: 'nope')], note: 'Nothing to change');

      expect(await s.send('b', mentionIds: []), isNull);

      final saved = await store().load();
      expect(saved.proposal, isNull);
      expect(saved.thread.last.role, 'assistant');
      expect(saved.thread.last.text, 'Nothing to change');
    });

    test('a failed send leaves the thread unchanged', () async {
      final s = await consented();
      when(
        () => api.send(token: any(named: 'token'), body: any(named: 'body')),
      ).thenThrow(const OrganizeApiException(OrganizeErrorKind.userLimit));
      await expectLater(
        s.send('hi', mentionIds: []),
        throwsKind(OrganizeErrorKind.userLimit),
      );

      when(() => calendar.findMyWeek()).thenThrow(Exception('backend'));
      await expectLater(
        s.send('hi', mentionIds: []),
        throwsKind(OrganizeErrorKind.failed),
      );
      expect((await s.state()).thread, isEmpty);
    });

    test('on 401 re-reads the token and retries once', () async {
      final s = await consented();
      tokens = ['t1', 't2', 't3', 't4'];
      final seen = <String>[];
      var fail = 1;
      when(
        () => api.send(token: any(named: 'token'), body: any(named: 'body')),
      ).thenAnswer((inv) async {
        seen.add(inv.namedArguments[#token] as String);
        if (fail-- > 0) {
          throw const OrganizeApiException(OrganizeErrorKind.unauthorized);
        }
        return const AssistReply(note: 'ok', actions: []);
      });

      await s.send('hi', mentionIds: []);
      expect(seen, ['t1', 't2']);

      fail = 2;
      await expectLater(
        s.send('hi', mentionIds: []),
        throwsKind(OrganizeErrorKind.unauthorized),
      );
      expect(seen, ['t1', 't2', 't3', 't4']);
    });
  });

  test('mentionsFor puts pinned items first, then mentions, without dupes',
      () async {
    final m = await service().mentionsFor(
      'weed the garden, then sprint',
      pinnedIds: ['b2', 'b3', 'gone'],
    );
    expect([for (final e in m) e.id], ['b2', 'b3', 'b1']);
    expect(m.every((e) => e.kind == 'board'), isTrue);
  });

  test('describe passes through to the engine', () {
    expect(service().describe(act(0), {}).text, 'cal.x');
  });

  group('apply', () {
    test('apply persists after each action', () async {
      await seed(
        proposal(
          [act(0), act(1), act(2)],
          ticked: {2, 0},
          edits: {
            2: {'title': 'Edited', 'n': 99},
          },
        ),
      );
      final s = service();
      final seen = <int>[];
      cal.beforeApply = () async {
        final saved = await store().load();
        expect(saved.proposal, isNull);
        seen.add(saved.applied.single.records.length);
      };

      final p = await s.apply();

      expect(
        calls,
        ['apply 0', 'apply 2 Edited'],
        reason: 'n is not editable, so its edit is ignored',
      );
      expect(seen, [0, 1], reason: 'saved before the first and after each');
      expect(p.status, AppliedStatus.applied);
      final saved = (await store().load()).applied.single;
      expect(saved.status, AppliedStatus.applied);
      expect(saved.records, hasLength(2));
      expect([for (final a in saved.actions) a.fields['n']], [0, 2]);
    });

    test('apply twice concurrently applies once', () async {
      await seed(proposal([act(0), act(1)]));
      final gate = Completer<void>();
      cal.beforeApply = () => gate.future;
      final s = service();

      final first = s.apply();
      await expectLater(s.apply(), throwsStateError);
      final busy = throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('busy')),
      );
      await expectLater(s.undo('p1'), busy);
      await expectLater(s.retry('p1'), busy);
      gate.complete();
      await first;

      expect(calls, ['apply 0', 'apply 1']);
      expect((await s.state()).applied, hasLength(1));
      await expectLater(s.apply(), throwsStateError);
    });

    test('retry resumes partial', () async {
      await seed(proposal([act(0), act(1), act(2)]));
      cal.failing.add(1);
      final s = service();

      expect((await s.apply()).status, AppliedStatus.partial);
      expect(calls, ['apply 0', 'apply 1']);

      expect((await s.retry('p1')).status, AppliedStatus.applied);
      expect(calls, ['apply 0', 'apply 1', 'apply 1', 'apply 2']);
      expect(
        (await store().load()).applied.single.status,
        AppliedStatus.applied,
      );

      await s.retry('p1');
      expect(calls, hasLength(4), reason: 'only partial ones are retried');
    });

    test('apply refuses when nothing is ticked', () async {
      await seed(proposal([act(0)], ticked: <int>{}));
      final s = service();

      await expectLater(s.apply(), throwsStateError);

      final saved = await store().load();
      expect(saved.proposal, isNotNull);
      expect(saved.applied, isEmpty);
      expect(calls, isEmpty);
    });

    test('apply refuses a temp id declared only by an unticked action',
        () async {
      await seed(
        proposal([act(0, temp: 'new:1'), act(1, ref: 'new:1')], ticked: {1}),
      );
      final s = service();

      await expectLater(s.apply(), throwsStateError);
      expect((await s.state()).applied, isEmpty);
      expect((await store().load()).proposal, isNotNull);

      (await s.state()).proposal!.ticked = {0, 1};
      await s.apply();
      expect(calls, ['apply 0', 'apply 1']);
    });

    test('retry resumes a proposal left applying by a failed save', () async {
      await seed(proposal([act(0)]));
      final s = service();
      kv.failSets = 1;

      await expectLater(s.apply(), throwsException);
      expect((await s.state()).applied.single.status, AppliedStatus.applying);
      expect(calls, isEmpty);

      expect((await s.retry('p1')).status, AppliedStatus.applied);
      expect(calls, ['apply 0']);
    });

    test('apply keeps the newest 20 applied in memory', () async {
      await seed(
        proposal([act(0)]),
        applied: [
          for (var i = 0; i < 20; i++)
            AppliedProposal(
              id: 'old$i',
              appliedAt: DateTime.utc(2026),
              actions: [],
              status: AppliedStatus.applied,
            ),
        ],
      );
      final s = service();

      await s.apply();

      final applied = (await s.state()).applied;
      expect(applied, hasLength(20));
      expect(applied.first.id, 'old1');
      expect(applied.last.id, 'p1');
    });

    test('undo marks undone and persists', () async {
      await seed(proposal([act(0), act(1)]));
      final s = service();
      await s.apply();

      final report = await s.undo('p1');

      expect(report.reverted, 2);
      expect(calls, ['apply 0', 'apply 1', 'undo 1', 'undo 0']);
      final saved = (await store().load()).applied.single;
      expect(saved.status, AppliedStatus.undone);
      expect(saved.records.every((r) => r.data['undone'] == true), isTrue);
    });
  });
}
