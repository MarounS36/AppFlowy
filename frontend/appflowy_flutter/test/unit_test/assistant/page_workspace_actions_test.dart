import 'package:appflowy/features/assistant/actions/page_workspace_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/page_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGateway extends Mock implements PageGateway {}

AssistAction act(String type, Map<String, dynamic> f) =>
    AssistAction(type: type, fields: {'type': type, ...f});

PageRef ref(
  String id, {
  String name = 'P',
  String parent = 's1',
  bool editable = true,
  bool fav = false,
}) =>
    PageRef(
      id: id,
      name: name,
      parentId: parent,
      layout: 'document',
      editable: editable,
      isFavorite: fav,
    );

void main() {
  late _MockGateway gw;
  late Map<String, ActionHandler> h;
  late ValidationScope scope;

  setUp(() {
    gw = _MockGateway();
    h = {for (final x in pageWorkspaceHandlers(gw)) x.type: x};
    scope = ValidationScope(
      knownIds: {'s1', 's2', 'p1', 'p2', 'p3', 'c1'},
      weekStart: DateTime(2026, 10, 19),
      readOnlyIds: {'p2'},
      items: {
        's1': {'layout': 'space', 'parent_id': ''},
        's2': {'layout': 'space', 'parent_id': ''},
        'p1': {'layout': 'document', 'parent_id': 's1'},
        'p2': {'layout': 'document', 'parent_id': 's1'},
        'p3': {'layout': 'document', 'parent_id': 's2'},
        'c1': {'layout': 'document', 'parent_id': 'p1'},
      },
    );
  });

  void page(String id, PageRef? r) =>
      when(() => gw.page(id)).thenAnswer((_) async => r);

  test('five handlers at workspace stage', () {
    expect(
      h.keys,
      [
        'page.rename',
        'page.move',
        'page.duplicate',
        'page.favorite',
        'page.delete',
      ],
    );
    expect(h.values.every((x) => x.stage == AssistStage.workspace), isTrue);
  });

  group('validate', () {
    test('locked and space targets dropped', () {
      for (final t in h.keys) {
        final f = {
          'name': 'N',
          'parent_id': 's2',
          'temp_id': 'new:1',
          'on': true,
        };
        expect(
          h[t]!.validate(act(t, {...f, 'page_id': 'p1'}), scope),
          isNull,
          reason: t,
        );
        expect(
          h[t]!.validate(act(t, {...f, 'page_id': 'p2'}), scope),
          'Page is locked',
        );
        expect(
          h[t]!.validate(act(t, {...f, 'page_id': 's1'}), scope),
          isNotNull,
        );
        expect(
          h[t]!.validate(act(t, {...f, 'page_id': 'zz'}), scope),
          isNotNull,
        );
      }
    });

    test('rename name checked, favorite on must be bool', () {
      expect(
        h['page.rename']!.validate(
          act('page.rename', {'page_id': 'p1', 'name': ' '}),
          scope,
        ),
        isNotNull,
      );
      expect(
        h['page.favorite']!.validate(
          act('page.favorite', {'page_id': 'p1', 'on': 'yes'}),
          scope,
        ),
        isNotNull,
      );
    });

    test('move parent, after and descendants', () {
      String? v(Map<String, dynamic> f) => h['page.move']!
          .validate(act('page.move', {'page_id': 'p1', ...f}), scope);
      expect(v({'parent_id': 's2', 'after_id': 'p3'}), isNull);
      expect(v({'parent_id': 's2', 'after_id': 'nope'}), isNotNull);
      expect(v({'parent_id': 'p1'}), isNotNull);
      expect(v({'parent_id': 'c1'}), isNotNull);
      expect(v({'parent_id': 'zz'}), isNotNull);
      scope.boundTemps.add('new:1');
      scope.items['new:1'] = {'created_by': 'page.create'};
      expect(v({'parent_id': 'new:1'}), isNull);
    });

    test('duplicate needs a temp id', () {
      expect(
        h['page.duplicate']!
            .validate(act('page.duplicate', {'page_id': 'p1'}), scope),
        isNotNull,
      );
    });
  });

  test('previews', () {
    const l = {'p1#parent': 'Home', 'p1': 'Trip', 's1': 'Home', 's2': 'Work'};
    var d = h['page.rename']!
        .describe(act('page.rename', {'page_id': 'p1', 'name': 'New'}), l);
    expect((d.text, d.before, d.after), ('Rename page', 'Trip', 'New'));
    expect(d.editable, ['name']);
    final mv = act('page.move', {'page_id': 'p1', 'parent_id': 's2'});
    d = h['page.move']!.describe(mv, l);
    expect((d.text, d.before, d.after), ('Move Trip', 'Home', 'Work'));
    expect(
      h['page.duplicate']!
          .describe(act('page.duplicate', {'page_id': 'p1'}), l)
          .text,
      'Duplicate Trip',
    );
    expect(
      h['page.favorite']!
          .describe(act('page.favorite', {'page_id': 'p1', 'on': true}), l)
          .text,
      'Add Trip to Favorites',
    );
    expect(
      h['page.favorite']!
          .describe(act('page.favorite', {'page_id': 'p1', 'on': false}), l)
          .text,
      'Remove Trip from Favorites',
    );
    d = h['page.delete']!.describe(act('page.delete', {'page_id': 'p1'}), l);
    expect((d.text, d.destructive), ('Move Trip to Trash', true));
    expect(d.editable, isEmpty);
  });

  group('rename', () {
    final a = act('page.rename', {'page_id': 'p1', 'name': ' New '});

    test('apply and undo', () async {
      page('p1', ref('p1', name: 'Old'));
      when(() => gw.rename(any(), any())).thenAnswer((_) async {});
      final r = await h['page.rename']!.apply(a, ApplyScope({}));
      expect(r.type, 'page.rename');
      page('p1', ref('p1', name: 'New'));
      expect(await h['page.rename']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.rename('p1', 'Old')).called(1);
    });

    test('undo skipped when renamed since, or gone', () async {
      page('p1', ref('p1', name: 'Old'));
      when(() => gw.rename(any(), any())).thenAnswer((_) async {});
      final r = await h['page.rename']!.apply(a, ApplyScope({}));
      page('p1', ref('p1', name: 'Other'));
      expect(await h['page.rename']!.undo(r), UndoOutcome.skippedChanged);
      page('p1', null);
      expect(await h['page.rename']!.undo(r), UndoOutcome.skippedGone);
    });

    test('apply throws when locked now', () async {
      page('p1', ref('p1', editable: false));
      expect(h['page.rename']!.apply(a, ApplyScope({})), throwsStateError);
      verifyNever(() => gw.rename(any(), any()));
    });

    test('apply re-checks an edited name', () async {
      page('p1', ref('p1', name: 'Old'));
      for (final n in ['', '  ', 'a\nb', 'x' * 121]) {
        await expectLater(
          h['page.rename']!.apply(
            act('page.rename', {'page_id': 'p1', 'name': n}),
            ApplyScope({}),
          ),
          throwsStateError,
          reason: n,
        );
      }
      verifyNever(() => gw.rename(any(), any()));
    });
  });

  group('move', () {
    final a = act(
      'page.move',
      {'page_id': 'p1', 'parent_id': 's2', 'after_id': 'p3'},
    );

    Future<UndoRecord> doApply() async {
      page('p1', ref('p1'));
      page('s2', ref('s2', parent: ''));
      when(() => gw.prevSiblingId('p1')).thenAnswer((_) async => 'p8');
      when(() => gw.move(any(), any(), any())).thenAnswer((_) async {});
      return h['page.move']!.apply(a, ApplyScope({}));
    }

    test('apply moves and undo restores parent and prev sibling', () async {
      final r = await doApply();
      verify(() => gw.move('p1', 's2', 'p3')).called(1);
      page('p1', ref('p1', parent: 's2'));
      page('s1', ref('s1', parent: ''));
      page('p8', ref('p8'));
      expect(await h['page.move']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.move('p1', 's1', 'p8')).called(1);
    });

    test('undo uses null prev when sibling left the parent', () async {
      final r = await doApply();
      page('p1', ref('p1', parent: 's2'));
      page('s1', ref('s1', parent: ''));
      page('p8', ref('p8', parent: 's9'));
      await h['page.move']!.undo(r);
      verify(() => gw.move('p1', 's1', null)).called(1);
    });

    test('undo skipped when moved since', () async {
      final r = await doApply();
      page('p1', ref('p1', parent: 's3'));
      expect(await h['page.move']!.undo(r), UndoOutcome.skippedChanged);
      page('p1', null);
      expect(await h['page.move']!.undo(r), UndoOutcome.skippedGone);
    });

    test('undo skipped when the old parent is gone', () async {
      final r = await doApply();
      page('p1', ref('p1', parent: 's2'));
      page('s1', null);
      expect(await h['page.move']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.move('p1', 's1', any()));
    });

    test('apply throws on a live cycle and moves nothing', () async {
      page('p1', ref('p1'));
      page('s2', ref('s2', parent: 'c1'));
      page('c1', ref('c1', parent: 'p1'));
      await expectLater(
        h['page.move']!.apply(a, ApplyScope({})),
        throwsStateError,
      );
      verifyNever(() => gw.move(any(), any(), any()));
    });

    test('validate: locked parent and after_id == page_id', () {
      scope.readOnlyIds.add('s2');
      expect(
        h['page.move']!.validate(
          act('page.move', {'page_id': 'p1', 'parent_id': 's2'}),
          scope,
        ),
        isNotNull,
      );
      scope.readOnlyIds.remove('s2');
      expect(
        h['page.move']!.validate(
          act(
            'page.move',
            {'page_id': 'p1', 'parent_id': 's2', 'after_id': 'p1'},
          ),
          scope,
        ),
        isNotNull,
      );
    });

    test('resolves temp parent', () async {
      page('p1', ref('p1'));
      page('p9', ref('p9', parent: ''));
      when(() => gw.prevSiblingId('p1')).thenAnswer((_) async => null);
      when(() => gw.move(any(), any(), any())).thenAnswer((_) async {});
      await h['page.move']!.apply(
        act('page.move', {'page_id': 'p1', 'parent_id': 'new:1'}),
        ApplyScope({'new:1': 'p9'}),
      );
      verify(() => gw.move('p1', 'p9', null)).called(1);
    });
  });

  group('duplicate', () {
    final a = act('page.duplicate', {'page_id': 'p1', 'temp_id': 'new:3'});

    void kids(String id, List<String> ids) =>
        when(() => gw.childIds(id)).thenAnswer((_) async => ids);

    test('binds copy; undo trashes it, skippedGone when gone', () async {
      page('p1', ref('p1'));
      when(() => gw.duplicate('p1')).thenAnswer((_) async => 'p7');
      when(() => gw.delete('p7')).thenAnswer((_) async {});
      page('p7', ref('p7', name: 'P (copy)'));
      kids('p7', ['k1']);
      final s = ApplyScope({});
      final r = await h['page.duplicate']!.apply(a, s);
      expect(s.tempIds, {'new:3': 'p7'});
      expect(r.data, {'page_id': 'p7', 'name': 'P (copy)', 'children': 1});
      expect(await h['page.duplicate']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.delete('p7')).called(1);
      page('p7', null);
      expect(await h['page.duplicate']!.undo(r), UndoOutcome.skippedGone);
    });

    test('undo keeps a copy renamed or given other pages since', () async {
      page('p1', ref('p1'));
      when(() => gw.duplicate('p1')).thenAnswer((_) async => 'p7');
      page('p7', ref('p7', name: 'P (copy)'));
      kids('p7', ['k1']);
      final r = await h['page.duplicate']!.apply(a, ApplyScope({}));
      page('p7', ref('p7', name: 'Mine'));
      expect(await h['page.duplicate']!.undo(r), UndoOutcome.skippedChanged);
      page('p7', ref('p7', name: 'P (copy)'));
      kids('p7', ['k1', 'k2']);
      expect(await h['page.duplicate']!.undo(r), UndoOutcome.skippedChanged);
      kids('p7', []);
      expect(await h['page.duplicate']!.undo(r), UndoOutcome.skippedChanged);
      verifyNever(() => gw.delete(any()));
    });

    test('a failed read of the copy trashes it and binds nothing', () async {
      page('p1', ref('p1'));
      when(() => gw.duplicate('p1')).thenAnswer((_) async => 'p7');
      when(() => gw.delete('p7')).thenAnswer((_) async {});
      page('p7', ref('p7'));
      when(() => gw.childIds('p7')).thenThrow(StateError('x'));
      final s = ApplyScope({});
      await expectLater(h['page.duplicate']!.apply(a, s), throwsStateError);
      verify(() => gw.delete('p7')).called(1);
      expect(s.tempIds, isEmpty);
    });

    test('failure binds nothing', () async {
      page('p1', ref('p1'));
      when(() => gw.duplicate('p1')).thenThrow(StateError('x'));
      final s = ApplyScope({});
      await expectLater(h['page.duplicate']!.apply(a, s), throwsStateError);
      expect(s.tempIds, isEmpty);
    });
  });

  group('favorite', () {
    AssistAction fav(bool on) =>
        act('page.favorite', {'page_id': 'p1', 'on': on});

    test('toggles and undo toggles back only if unchanged', () async {
      page('p1', ref('p1'));
      when(() => gw.setFavorite(any(), any())).thenAnswer((_) async {});
      final r = await h['page.favorite']!.apply(fav(true), ApplyScope({}));
      verify(() => gw.setFavorite('p1', true)).called(1);
      page('p1', ref('p1'));
      expect(await h['page.favorite']!.undo(r), UndoOutcome.skippedChanged);
      page('p1', ref('p1', fav: true));
      expect(await h['page.favorite']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.setFavorite('p1', false)).called(1);
    });

    test('already equal is a no-op and undo writes nothing', () async {
      page('p1', ref('p1', fav: true));
      final r = await h['page.favorite']!.apply(fav(true), ApplyScope({}));
      expect(await h['page.favorite']!.undo(r), UndoOutcome.reverted);
      verifyNever(() => gw.setFavorite(any(), any()));
    });
  });

  group('delete', () {
    test('undo is skippedGone when restore fails', () async {
      page('p1', null);
      when(() => gw.restore('p1')).thenThrow(StateError('gone'));
      final r = UndoRecord(type: 'page.delete', data: {'page_id': 'p1'});
      expect(await h['page.delete']!.undo(r), UndoOutcome.skippedGone);
    });

    final a = act('page.delete', {'page_id': 'p1'});

    test('apply deletes; undo restores, idempotent if page is back', () async {
      page('p1', ref('p1'));
      when(() => gw.delete('p1')).thenAnswer((_) async {});
      when(() => gw.restore('p1')).thenAnswer((_) async {});
      final r = await h['page.delete']!.apply(a, ApplyScope({}));
      expect(r.type, 'page.delete');
      page('p1', null);
      expect(await h['page.delete']!.undo(r), UndoOutcome.reverted);
      page('p1', ref('p1'));
      expect(await h['page.delete']!.undo(r), UndoOutcome.reverted);
      verify(() => gw.restore('p1')).called(1);
    });
  });
}
