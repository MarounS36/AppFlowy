import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/core/config/kv_keys.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/data/organize_store.dart';
import 'package:appflowy_backend/log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

OrganizeProposal _proposal(
  String id, {
  String? title,
  ProposalState state = ProposalState.needsReview,
  DateTime? createdAt,
}) =>
    OrganizeProposal(
      id: id,
      noteId: 'n$id',
      createdAt: createdAt ?? DateTime.utc(2026),
      snapshot: const NoteSnapshot(title: 't', parentId: 'p', bodyHash: 'h'),
      proposedTitle: title,
      currentFolderPath: 'A',
      reason: 'r',
      state: state,
    );

HistoryEntry _entry(int i) => HistoryEntry(
      proposalId: 'p$i',
      noteId: 'n',
      field: OrganizeField.title,
      appliedAt: DateTime.utc(2026).add(Duration(minutes: i)),
      before: 'a',
      after: 'b',
      beforeLabel: 'a',
      afterLabel: 'b',
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
    final s = await OrganizeStore(kv: kv, userId: 'u1').load();
    expect(s.enabled, true);
    expect(s.consented, false);
    expect(s.proposals, isEmpty);
    expect(s.history, isEmpty);
    expect(s.rejections, isEmpty);
  });

  test('save then load round trips', () async {
    final store = OrganizeStore(kv: kv, userId: 'u1');
    final state = OrganizeState(
      enabled: false,
      consented: true,
      proposals: [_proposal('1', title: 'X')],
      history: [_entry(1)],
      rejections: {'n1': Rejections(bodyHash: 'h', titles: ['x'])},
    );
    await store.save(state);
    final loaded = await store.load();
    expect(loaded.toJson(), state.toJson());
  });

  test('users are isolated', () async {
    await OrganizeStore(kv: kv, userId: 'u1')
        .save(OrganizeState(consented: true, history: [_entry(1)]));
    final s = await OrganizeStore(kv: kv, userId: 'u2').load();
    expect(s.consented, false);
    expect(s.history, isEmpty);
  });

  test('interrupted proposals recover on load', () async {
    final store = OrganizeStore(kv: kv, userId: 'u1');
    await store.save(
      OrganizeState(
        proposals: [
          _proposal('a', title: 'X', state: ProposalState.processing),
          _proposal('b', state: ProposalState.processing),
        ],
      ),
    );
    final p = (await store.load()).proposals;
    expect(p[0].state, ProposalState.stale);
    expect(p[1].state, ProposalState.failed);
    expect(p[1].error, OrganizeErrorKind.failed);
  });

  test('save trims to newest 200', () async {
    final store = OrganizeStore(kv: kv, userId: 'u1');
    await store.save(
      OrganizeState(
        history: [for (var i = 0; i < 205; i++) _entry(i)],
        proposals: [
          for (var i = 0; i < 205; i++)
            _proposal(
              '$i',
              createdAt: DateTime.utc(2026).add(Duration(minutes: i)),
            ),
        ],
      ),
    );
    final s = await store.load();
    expect(s.history, hasLength(200));
    expect(s.history.first.proposalId, 'p5');
    expect(s.proposals, hasLength(200));
    expect(s.proposals.first.id, '5');
  });

  for (final bad in [
    '{not json',
    '{"proposals":[{"id":"1","noteId":"n","createdAt":"2026-01-01T00:00:00.000Z",'
        '"snapshot":{"title":"t","parentId":"p","bodyHash":"h"},'
        '"currentFolderPath":"A","reason":"r","state":"bogus"}]}',
  ]) {
    test('corrupt data loads defaults: $bad', () async {
      await kv.set('${KVKeys.aiOrganize}.u1', bad);
      final s = await OrganizeStore(kv: kv, userId: 'u1').load();
      expect(s.proposals, isEmpty);
      expect(s.enabled, true);
    });
  }
}
