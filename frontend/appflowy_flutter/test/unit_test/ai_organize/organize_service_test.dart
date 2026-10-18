import 'dart:async';
import 'dart:convert';

import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_backend.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/data/organize_store.dart';
import 'package:appflowy/features/ai_organize/logic/organize_rules.dart';
import 'package:appflowy/features/ai_organize/logic/organize_service.dart';
import 'package:appflowy/workspace/application/view/view_ext.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-error/errors.pb.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockBackend extends Mock implements OrganizeBackend {}

class _MockApi extends Mock implements OrganizeApi {}

typedef _Note = ({NoteSnapshot snapshot, String text});

ViewPB _view(String id, String parent, String name, {bool space = false}) {
  final v = ViewPB()
    ..id = id
    ..parentViewId = parent
    ..name = name
    ..layout = ViewLayoutPB.Document;
  if (space) {
    v.extra = jsonEncode({
      ViewExtKeys.isSpaceKey: true,
      ViewExtKeys.spacePermissionKey: 0,
    });
  }
  return v;
}

/// Space / Inbox (holds n1) and Space / Home (holds h1).
final _views = [
  _view('space', 'ws', 'Space', space: true),
  _view('inbox', 'space', 'Inbox'),
  _view('n1', 'inbox', 'untitled'),
  _view('home', 'space', 'Home'),
  _view('h1', 'home', 'Bills'),
];

_Note _note({
  String title = 'untitled',
  String parent = 'inbox',
  String text = 'groceries',
  String? prev,
}) =>
    (
      snapshot: NoteSnapshot(
        title: title,
        parentId: parent,
        prevSiblingId: prev,
        bodyHash: bodyHash(text),
      ),
      text: text,
    );

const _both = OrganizeDecision(title: 'Groceries', folderId: 'home');

void main() {
  late _MockBackend backend;
  late _MockApi api;
  late KeyValueStorage kv;

  OrganizeStore store() => OrganizeStore(kv: kv, userId: 'u1');
  OrganizeService service() =>
      OrganizeService(backend: backend, store: store(), api: api);

  void suggest({String? title = 'Groceries', String? folderId = 'home'}) =>
      when(
        () => api.organize(
          token: any(named: 'token'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async =>
            OrganizeSuggestion(title: title, folderId: folderId, reason: 'r'),
      );

  void apiThrows(OrganizeErrorKind kind) => when(
        () => api.organize(
          token: any(named: 'token'),
          body: any(named: 'body'),
        ),
      ).thenThrow(OrganizeApiException(kind));

  void noteIs(_Note? note) =>
      when(() => backend.readNote('n1')).thenAnswer((_) async => note);

  void viewIs({String title = 'untitled', String parent = 'inbox'}) =>
      when(() => backend.view('n1'))
          .thenAnswer((_) async => _view('n1', parent, title));

  List<Map<String, dynamic>> sentBodies() => verify(
        () => api.organize(
          token: any(named: 'token'),
          body: captureAny(named: 'body'),
        ),
      ).captured.cast<Map<String, dynamic>>();

  void verifyNoWrites() {
    verifyNever(() => backend.rename(any(), any()));
    verifyNever(
      () => backend.move(
        any(),
        parentId: any(named: 'parentId'),
        prevViewId: any(named: 'prevViewId'),
      ),
    );
  }

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    Log.shared.disableLog = true;
    kv = DartKeyValue();
    backend = _MockBackend();
    api = _MockApi();
    final byId = {for (final v in _views) v.id: v};
    when(() => backend.accessToken()).thenAnswer((_) async => 'tok');
    when(() => backend.allViews()).thenAnswer((_) async => _views);
    when(() => backend.view(any()))
        .thenAnswer((i) async => byId[i.positionalArguments.first]);
    when(() => backend.canEdit(any())).thenAnswer((_) async => true);
    when(() => backend.rename(any(), any())).thenAnswer((_) async {});
    when(
      () => backend.move(
        any(),
        parentId: any(named: 'parentId'),
        prevViewId: any(named: 'prevViewId'),
      ),
    ).thenAnswer((_) async {});
    noteIs(_note());
    suggest();
  });

  Future<(OrganizeService, String)> applied(OrganizeDecision d) async {
    final s = service();
    final p = (await s.request('n1'))!;
    await s.apply(p.id, d);
    // Undo compares title and parent only; it must not need the body.
    when(() => backend.readNote(any())).thenThrow(FlowyError());
    return (s, (await s.state()).history.last.key);
  }

  test('request stores needsReview proposal with snapshot', () async {
    final p = (await service().request('n1'))!;

    expect(p.state, ProposalState.needsReview);
    expect(p.snapshot.toJson(), _note().snapshot.toJson());
    expect(p.proposedTitle, 'Groceries');
    expect(p.proposedFolderId, 'home');
    expect(p.proposedFolderPath, 'Space / Home');
    expect(p.currentFolderPath, 'Space / Inbox');
    expect(p.reason, 'r');
    expect(p.createdAt.isUtc, true);
    expect((await store().load()).proposals.single.toJson(), p.toJson());
    expect(sentBodies().single, {
      'note': {
        'id': 'n1',
        'title': 'untitled',
        'text': 'groceries',
        'current_parent_id': 'inbox',
      },
      'folders': [
        {'id': 'space', 'path': 'Space'},
        {'id': 'home', 'path': 'Space / Home'},
        {'id': 'inbox', 'path': 'Space / Inbox'},
      ],
      'exclude': {'titles': [], 'folder_ids': []},
    });
    verifyNoWrites();
  });

  test('request truncates text and sends only editable folders', () async {
    final long = 'x' * (kMaxNoteChars + 10);
    noteIs(_note(text: long));
    when(() => backend.canEdit('space')).thenAnswer((_) async => false);

    await service().request('n1');

    final body = sentBodies().single;
    expect((body['note'] as Map)['text'], long.substring(0, kMaxNoteChars));
    expect(
      (body['folders'] as List).map((f) => (f as Map)['id']),
      ['home', 'inbox'],
    );
  });

  test('request drops a folder that was not offered', () async {
    suggest(folderId: 'h1');
    final p = (await service().request('n1'))!;
    expect(p.proposedTitle, 'Groceries');
    expect(p.proposedFolderId, isNull);
    expect(p.proposedFolderPath, isNull);
  });

  test('request on missing note throws noteMissing', () async {
    noteIs(null);
    await expectLater(
      service().request('n1'),
      throwsA(
        isA<OrganizeApiException>()
            .having((e) => e.kind, 'kind', OrganizeErrorKind.noteMissing),
      ),
    );
    verifyNever(
      () => api.organize(
        token: any(named: 'token'),
        body: any(named: 'body'),
      ),
    );
  });

  test('request maps backend read errors to failed', () async {
    when(() => backend.readNote('n1')).thenThrow(FlowyError());
    await expectLater(
      service().request('n1'),
      throwsA(
        isA<OrganizeApiException>()
            .having((e) => e.kind, 'kind', OrganizeErrorKind.failed),
      ),
    );
  });

  test('request sends exclude only while body hash unchanged', () async {
    final s = service();
    await s.reject((await s.request('n1'))!.id);

    await s.request('n1');
    expect(sentBodies().last['exclude'], {
      'titles': ['Groceries'],
      'folder_ids': ['home'],
    });

    noteIs(_note(text: 'groceries and milk'));
    await s.request('n1');
    expect(sentBodies().last['exclude'], {'titles': [], 'folder_ids': []});
    expect((await s.state()).rejections, isEmpty);
  });

  test('request retries once with fresh token on unauthorized', () async {
    var tokens = 0;
    when(() => backend.accessToken()).thenAnswer((_) async => 't${++tokens}');
    var calls = 0;
    when(
      () => api.organize(
        token: any(named: 'token'),
        body: any(named: 'body'),
      ),
    ).thenAnswer((_) async {
      if (++calls == 1) {
        throw const OrganizeApiException(OrganizeErrorKind.unauthorized);
      }
      return const OrganizeSuggestion(title: 'Groceries', reason: 'r');
    });

    final p = (await service().request('n1'))!;
    expect(p.state, ProposalState.needsReview);
    verify(() => backend.accessToken()).called(2);
    verify(
      () => api.organize(token: 't2', body: any(named: 'body')),
    ).called(1);

    apiThrows(OrganizeErrorKind.unauthorized);
    final failed = (await service().request('n1'))!;
    expect(failed.state, ProposalState.failed);
    expect(failed.error, OrganizeErrorKind.unauthorized);
    verify(() => backend.accessToken()).called(2);
  });

  test('request failure leaves note untouched', () async {
    apiThrows(OrganizeErrorKind.failed);
    final s = service();
    final p = (await s.request('n1'))!;
    expect(p.state, ProposalState.failed);
    expect(p.error, OrganizeErrorKind.failed);
    expect(
      (await store().load()).proposals.single.state,
      ProposalState.failed,
    );
    verifyNoWrites();
  });

  test('request with nothing to suggest stores nothing', () async {
    final s = service();
    await s.request('n1');
    expect((await s.state()).proposals, hasLength(1));

    suggest(title: null, folderId: null);
    expect(await s.request('n1'), isNull);
    expect((await s.state()).proposals, isEmpty);
    expect((await store().load()).proposals, isEmpty);
  });

  test('request replaces the open proposal for the note', () async {
    final s = service();
    final first = (await s.request('n1'))!;
    final second = (await s.request('n1'))!;
    expect(
      (await s.state()).proposals.map((p) => p.id),
      [second.id],
    );
    expect(second.id, isNot(first.id));
  });

  test('apply only performs accepted fields', () async {
    final s = service();
    final p = (await s.request('n1'))!;

    final result =
        await s.apply(p.id, const OrganizeDecision(title: 'Groceries'));

    expect(result, ProposalState.partiallyApplied);
    verify(() => backend.rename('n1', 'Groceries')).called(1);
    verifyNever(
      () => backend.move(
        any(),
        parentId: any(named: 'parentId'),
        prevViewId: any(named: 'prevViewId'),
      ),
    );
    final state = await s.state();
    final h = state.history.single;
    expect(h.field, OrganizeField.title);
    expect(h.before, 'untitled');
    expect(h.after, 'Groceries');
    expect(h.appliedAt.isUtc, true);
    expect(state.rejections['n1']!.folderIds, ['home']);
    expect(state.rejections['n1']!.titles, isEmpty);
    expect(
      (await store().load()).proposals.single.state,
      ProposalState.partiallyApplied,
    );
  });

  test('apply twice concurrently applies once', () async {
    final id = (await service().request('n1'))!.id;
    // A fresh service: both calls race on the first state load.
    final s = service();

    final results = await Future.wait([s.apply(id, _both), s.apply(id, _both)]);

    expect(results.where((r) => r == ProposalState.applied), hasLength(1));
    verify(() => backend.rename('n1', 'Groceries')).called(1);
    verify(
      () => backend.move('n1', parentId: 'home'),
    ).called(1);
    expect((await s.state()).history, hasLength(2));
    expect(await s.apply(id, _both), ProposalState.applied);
    verifyNever(() => backend.rename(any(), any()));
  });

  test('request keeps a proposal whose apply is in flight', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    final gate = Completer<_Note?>();
    final reached = Completer<void>();
    when(() => backend.readNote('n1')).thenAnswer((_) {
      if (reached.isCompleted) return Future.value(_note());
      reached.complete();
      return gate.future;
    });

    final applying = s.apply(p.id, _both);
    await reached.future; // apply is parked on its note re-read
    final newer = (await s.request('n1'))!;
    gate.complete(_note());

    expect(await applying, ProposalState.applied);
    final state = await s.state();
    expect(state.proposals.map((x) => x.id), [p.id, newer.id]);
    expect(state.proposals.first.state, ProposalState.applied);
    expect(state.history.map((h) => h.proposalId), [p.id, p.id]);
    final saved = await store().load();
    expect(saved.proposals.first.state, ProposalState.applied);
    expect(saved.history, hasLength(2));
  });

  test('apply marks stale when note changed', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    noteIs(_note(title: 'Shopping'));

    expect(await s.apply(p.id, _both), ProposalState.stale);
    verifyNoWrites();
    expect(await s.apply(p.id, _both), ProposalState.stale);
    verifyNoWrites();

    expect(await s.apply(p.id, _both, force: true), ProposalState.applied);
    verify(() => backend.rename('n1', 'Groceries')).called(1);
    verify(
      () => backend.move('n1', parentId: 'home'),
    ).called(1);
    expect((await s.state()).history.first.before, 'Shopping');
  });

  test('apply force on needsReview still checks staleness', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    noteIs(_note(title: 'Shopping'));

    expect(await s.apply(p.id, _both, force: true), ProposalState.stale);
    verifyNoWrites();
  });

  test('apply skips no-op rename', () async {
    final s = service();
    final p = (await s.request('n1'))!;

    await s.apply(p.id, const OrganizeDecision(title: 'untitled'));

    verifyNever(() => backend.rename(any(), any()));
    expect((await s.state()).history, isEmpty);
  });

  test('apply on deleted note fails without writes', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    noteIs(null);

    expect(await s.apply(p.id, _both), ProposalState.failed);
    expect(p.error, OrganizeErrorKind.noteMissing);
    verifyNoWrites();
    expect((await s.state()).history, isEmpty);
  });

  test('apply keeps title when move fails', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    when(
      () => backend.move(
        any(),
        parentId: any(named: 'parentId'),
        prevViewId: any(named: 'prevViewId'),
      ),
    ).thenThrow(FlowyError());

    expect(await s.apply(p.id, _both), ProposalState.partiallyApplied);
    expect(p.error, OrganizeErrorKind.failed);
    expect((await s.state()).history.single.field, OrganizeField.title);
    final saved = await store().load();
    expect(saved.proposals.single.state, ProposalState.partiallyApplied);
    expect(saved.history, hasLength(1));
  });

  test('apply refuses a destination that is no longer a folder', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    // Home was locked after the suggestion.
    when(() => backend.allViews()).thenAnswer(
      (_) async => [
        for (final v in _views)
          v.id == 'home'
              ? (_view('home', 'space', 'Home')..isLocked = true)
              : v,
      ],
    );

    expect(await s.apply(p.id, _both), ProposalState.partiallyApplied);
    verify(() => backend.rename('n1', 'Groceries')).called(1);
    verifyNever(
      () => backend.move(
        any(),
        parentId: any(named: 'parentId'),
        prevViewId: any(named: 'prevViewId'),
      ),
    );
  });

  test('apply fails without writes when rename throws', () async {
    final s = service();
    final p = (await s.request('n1'))!;
    when(() => backend.rename(any(), any())).thenThrow(FlowyError());

    expect(await s.apply(p.id, _both), ProposalState.failed);
    expect(p.error, OrganizeErrorKind.failed);
    expect((await s.state()).history, isEmpty);
  });

  test('reject records rejections', () async {
    final s = service();
    final p = (await s.request('n1'))!;

    await s.reject(p.id);

    final state = await store().load();
    expect(state.proposals.single.state, ProposalState.rejected);
    final r = state.rejections['n1']!;
    expect(r.bodyHash, bodyHash('groceries'));
    expect(r.titles, ['Groceries']);
    expect(r.folderIds, ['home']);
    verifyNoWrites();
  });

  test('undo restores title when unchanged since', () async {
    final (s, key) = await applied(const OrganizeDecision(title: 'Groceries'));
    viewIs(title: 'Groceries');

    expect(await s.undo(key), UndoResult.undone);
    verify(() => backend.rename('n1', 'untitled')).called(1);
    expect((await store().load()).history.single.undone, true);
  });

  test('undo reports conflict when title changed since', () async {
    final (s, key) = await applied(const OrganizeDecision(title: 'Groceries'));
    viewIs(title: 'Other');

    expect(await s.undo(key), UndoResult.conflict);
    verifyNever(() => backend.rename('n1', 'untitled'));
    expect((await s.state()).history.single.undone, false);
  });

  test('undo restores folder after its previous sibling', () async {
    noteIs(_note(prev: 'p0'));
    final (s, key) = await applied(const OrganizeDecision(folderId: 'home'));
    viewIs(parent: 'home');
    when(() => backend.view('p0'))
        .thenAnswer((_) async => _view('p0', 'inbox', 'P0'));

    expect(await s.undo(key), UndoResult.undone);
    verify(
      () => backend.move('n1', parentId: 'inbox', prevViewId: 'p0'),
    ).called(1);
  });

  test('undo drops previous sibling that moved away', () async {
    noteIs(_note(prev: 'p0'));
    final (s, key) = await applied(const OrganizeDecision(folderId: 'home'));
    viewIs(parent: 'home');
    when(() => backend.view('p0'))
        .thenAnswer((_) async => _view('p0', 'home', 'P0'));

    expect(await s.undo(key), UndoResult.undone);
    verify(
      () => backend.move('n1', parentId: 'inbox'),
    ).called(1);
  });

  test('undo reports conflict when original parent is gone', () async {
    final (s, key) = await applied(const OrganizeDecision(folderId: 'home'));
    viewIs(parent: 'home');
    when(() => backend.view('inbox')).thenAnswer((_) async => null);

    expect(await s.undo(key), UndoResult.conflict);
    verifyNever(
      () => backend.move(
        'n1',
        parentId: 'inbox',
        prevViewId: any(named: 'prevViewId'),
      ),
    );
  });

  test('undo reports conflict when original parent moved under the note',
      () async {
    final (s, key) = await applied(const OrganizeDecision(folderId: 'home'));
    viewIs(parent: 'home');
    when(() => backend.view('inbox'))
        .thenAnswer((_) async => _view('inbox', 'n1', 'Inbox'));

    expect(await s.undo(key), UndoResult.conflict);
    verifyNever(
      () => backend.move(
        'n1',
        parentId: 'inbox',
        prevViewId: any(named: 'prevViewId'),
      ),
    );
  });

  test('undo reports conflict when note is gone', () async {
    final (s, key) = await applied(const OrganizeDecision(title: 'Groceries'));
    when(() => backend.view('n1')).thenAnswer((_) async => null);

    expect(await s.undo(key), UndoResult.conflict);
    verifyNever(() => backend.rename('n1', 'untitled'));
  });

  test('undo twice returns alreadyUndone', () async {
    final (s, key) = await applied(const OrganizeDecision(title: 'Groceries'));
    viewIs(title: 'Groceries');

    expect(await s.undo(key), UndoResult.undone);
    expect(await s.undo(key), UndoResult.alreadyUndone);
    verify(() => backend.rename('n1', 'untitled')).called(1);
  });
}
