import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/core/config/kv_keys.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/data/assistant_store.dart';
import 'package:appflowy_backend/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppliedProposal _applied(int i, {AppliedStatus? status}) => AppliedProposal(
      id: 'a$i',
      appliedAt: DateTime.utc(2026).add(Duration(minutes: i)),
      actions: [
        AssistAction(type: 'x', fields: {'n': i}),
      ],
      status: status ?? AppliedStatus.applied,
    );

void main() {
  late KeyValueStorage kv;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Log.shared.disableLog = true;
    kv = DartKeyValue();
  });

  test('load returns defaults when empty', () async {
    final s = await AssistantStore(kv: kv, userId: 'u1').load();
    expect(s.enabled, true);
    expect(s.consentedStage, AssistStage.none);
    expect(s.thread, isEmpty);
    expect(s.proposal, isNull);
    expect(s.applied, isEmpty);
  });

  test('save then load round trips', () async {
    final store = AssistantStore(kv: kv, userId: 'u1');
    final proposal = Proposal(
      id: 'p',
      actions: [
        AssistAction(
          type: 'create_board',
          fields: {
            'board_id': 'b',
            'temp_id': 't1',
            'columns': [
              {'temp_id': 'c', 'name': 'Todo'},
            ],
          },
        ),
        AssistAction(type: 'delete_page', fields: {'page_id': 'x'}),
      ],
      note: 'n',
      weekStart: '2026-01-05',
      labels: {'x': 'X'},
      ticked: {1},
      edits: {
        0: {'name': 'New'},
      },
    );
    final state = AssistantState(
      enabled: false,
      consentedStage: AssistStage.pages,
      thread: [ChatTurn(role: 'user', text: 'hi')],
      proposal: proposal,
      applied: [
        AppliedProposal(
          id: 'a',
          appliedAt: DateTime.utc(2026),
          actions: proposal.actions,
          records: [
            UndoRecord(type: 'r', data: {'k': 1}),
          ],
          tempIds: {'t1': 'real'},
          labels: {'b1': 'Move'},
          status: AppliedStatus.partial,
          error: 'boom',
        ),
      ],
    );
    await store.save(state);
    final loaded = await store.load();
    expect(loaded.toJson(), state.toJson());
    expect(loaded.proposal!.edits[0], {'name': 'New'});
    expect(loaded.proposal!.ticked, {1});
    expect(loaded.proposal!.actions.first.tempId, 't1');
    expect(loaded.applied.first.appliedAt.isUtc, true);
    expect(loaded.applied.first.labels, {'b1': 'Move'});
  });

  test('ticked defaults to all indexes', () {
    final p = Proposal(
      id: 'p',
      actions: [
        AssistAction(type: 'a', fields: {}),
        AssistAction(type: 'b', fields: {}),
      ],
      note: '',
      weekStart: '',
      labels: {},
    );
    expect(p.ticked, {0, 1});
    expect(p.edits, isEmpty);
  });

  test('users are isolated', () async {
    await AssistantStore(kv: kv, userId: 'u1')
        .save(AssistantState(enabled: false));
    final s = await AssistantStore(kv: kv, userId: 'u2').load();
    expect(s.enabled, true);
  });

  test('applying becomes partial on load', () async {
    final store = AssistantStore(kv: kv, userId: 'u1');
    await store.save(
      AssistantState(
        applied: [_applied(1, status: AppliedStatus.applying), _applied(2)],
      ),
    );
    final a = (await store.load()).applied;
    expect(a[0].status, AppliedStatus.partial);
    expect(a[1].status, AppliedStatus.applied);
  });

  test('save trims to 20 applied and 10 turns', () async {
    final store = AssistantStore(kv: kv, userId: 'u1');
    await store.save(
      AssistantState(
        thread: [
          for (var i = 0; i < 13; i++) ChatTurn(role: 'user', text: '$i'),
        ],
        applied: [for (var i = 0; i < 25; i++) _applied(i)],
      ),
    );
    final s = await store.load();
    expect(s.applied, hasLength(20));
    expect(s.applied.first.id, 'a5');
    expect(s.thread, hasLength(10));
    expect(s.thread.first.text, '3');
  });

  for (final bad in [
    '{not json',
    '{"applied":[{"id":"1","appliedAt":"2026-01-01T00:00:00.000Z",'
        '"actions":[],"status":"bogus"}]}',
  ]) {
    test('corrupt data loads defaults: $bad', () async {
      await kv.set('${KVKeys.assistant}.u1', bad);
      final s = await AssistantStore(kv: kv, userId: 'u1').load();
      expect(s.applied, isEmpty);
      expect(s.enabled, true);
    });
  }
}
