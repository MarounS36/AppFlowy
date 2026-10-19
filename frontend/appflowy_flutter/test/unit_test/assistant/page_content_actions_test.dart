import 'package:appflowy/features/assistant/actions/page_content_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/page_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_engine.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGateway extends Mock implements PageGateway {}

AssistAction act(String type, Map<String, dynamic> f) =>
    AssistAction(type: type, fields: {'type': type, ...f});

PageRef ref(
  String id, {
  String name = 'P',
  String layout = 'document',
  bool editable = true,
}) =>
    PageRef(
      id: id,
      name: name,
      parentId: 's1',
      layout: layout,
      editable: editable,
    );

void main() {
  late _MockGateway gw;
  late Map<String, ActionHandler> h;
  late ValidationScope scope;

  setUp(() {
    gw = _MockGateway();
    h = {for (final x in pageContentHandlers(gw)) x.type: x};
    scope = ValidationScope(
      knownIds: {'s1', 'p1', 'p2', 'g1'},
      weekStart: DateTime(2026, 10, 19),
      readOnlyIds: {'p2'},
      items: {
        's1': {'layout': 'space'},
        'p1': {'layout': 'document'},
        'p2': {'layout': 'document'},
        'g1': {'layout': 'grid'},
      },
    );
  });

  void page(String id, PageRef? r) =>
      when(() => gw.page(id)).thenAnswer((_) async => r);

  void md(String id, String? text) => when(
        () => gw.markdown(id, cap: any(named: 'cap')),
      ).thenAnswer((_) async => text);

  void kids(String id, List<String> ids) =>
      when(() => gw.childIds(id)).thenAnswer((_) async => ids);

  AssistAction create(Map<String, dynamic> f) => act('page.create', {
        'temp_id': 'new:2',
        'parent_id': 's1',
        'name': 'Packing',
        'content': '- [ ] Socks',
        ...f,
      });

  AssistAction append(Map<String, dynamic> f) =>
      act('page.append', {'page_id': 'p1', 'content': 'More', ...f});

  test('handlers are page.create and page.append at stage pages', () {
    expect(h.keys, ['page.create', 'page.append']);
    expect(h.values.every((x) => x.stage == AssistStage.pages), isTrue);
  });

  test('create binds temp id and parent resolves new:N', () async {
    page('p9', ref('p9'));
    when(() => gw.createPage('p9', 'Packing', '- [ ] Socks'))
        .thenAnswer((_) async => 'p10');
    md('p10', '- [ ] Socks\n');
    final s = ApplyScope({'new:1': 'p9'});
    final r = await h['page.create']!.apply(
      create({'parent_id': 'new:1', 'name': ' Packing '}),
      s,
    );
    expect(s.tempIds, {'new:1': 'p9', 'new:2': 'p10'});
    expect(r.type, 'page.create');
    expect(r.data, {'page_id': 'p10', 'markdown': '- [ ] Socks\n'});
  });

  test('create failure binds nothing', () async {
    page('s1', ref('s1', layout: 'space'));
    when(() => gw.createPage(any(), any(), any())).thenThrow(StateError('x'));
    final s = ApplyScope({});
    await expectLater(h['page.create']!.apply(create({}), s), throwsStateError);
    expect(s.tempIds, isEmpty);
  });

  test('undo create trashes the page; gone is skipped', () async {
    final rec = UndoRecord(
      type: 'page.create',
      data: {'page_id': 'p10', 'markdown': 'Socks'},
    );
    page('p10', ref('p10'));
    md('p10', 'Socks');
    kids('p10', []);
    when(() => gw.delete('p10')).thenAnswer((_) async {});
    expect(await h['page.create']!.undo(rec), UndoOutcome.reverted);
    verify(() => gw.delete('p10')).called(1);
    page('p10', null);
    expect(await h['page.create']!.undo(rec), UndoOutcome.skippedGone);
    verifyNever(() => gw.delete('p10'));
  });

  test('undo create keeps a page written in or given pages since', () async {
    final rec = UndoRecord(
      type: 'page.create',
      data: {'page_id': 'p10', 'markdown': 'Socks'},
    );
    page('p10', ref('p10'));
    md('p10', 'Socks and more');
    kids('p10', []);
    expect(await h['page.create']!.undo(rec), UndoOutcome.skippedChanged);
    md('p10', 'Socks');
    kids('p10', ['p11']);
    expect(await h['page.create']!.undo(rec), UndoOutcome.skippedChanged);
    verifyNever(() => gw.delete(any()));
  });

  test('apply re-checks edited name and content before any write', () async {
    page('s1', ref('s1', layout: 'space'));
    page('p1', ref('p1'));
    for (final a in [
      create({'name': ' '}),
      create({'name': 'a\nb'}),
      create({'content': '  '}),
      create({'content': 'x' * 20001}),
      append({'content': ''}),
      append({'content': 'x' * 20001}),
    ]) {
      await expectLater(
        h[a.type]!.apply(a, ApplyScope({})),
        throwsStateError,
        reason: a.type,
      );
    }
    verifyNever(() => gw.createPage(any(), any(), any()));
    verifyNever(() => gw.append(any(), any()));
  });

  void remove(bool result) => when(
        () => gw.removeBlocksIfUnchanged(
          any(),
          blockIds: any(named: 'blockIds'),
          padIds: any(named: 'padIds'),
          expectedMarkdown: any(named: 'expectedMarkdown'),
        ),
      ).thenAnswer((_) async => result);

  test('append undo removes blocks when unchanged, idempotent', () async {
    page('p1', ref('p1'));
    when(() => gw.append('p1', 'More')).thenAnswer(
      (_) async => (contentIds: ['k1', 'k2'], padIds: ['x1', 'x2']),
    );
    final r = await h['page.append']!.apply(append({}), ApplyScope({}));
    expect(r.type, 'page.append');
    expect(r.data, {
      'page_id': 'p1',
      'block_ids': ['k1', 'k2'],
      'pad_ids': ['x1', 'x2'],
      'markdown': 'More',
    });
    remove(true);
    expect(await h['page.append']!.undo(r), UndoOutcome.reverted);
    expect(await h['page.append']!.undo(r), UndoOutcome.skippedGone);
    verify(
      () => gw.removeBlocksIfUnchanged(
        'p1',
        blockIds: ['k1', 'k2'],
        padIds: ['x1', 'x2'],
        expectedMarkdown: 'More',
      ),
    ).called(1);
  });

  test('append undo skipped when the user edited those blocks', () async {
    final r = UndoRecord(
      type: 'page.append',
      data: {
        'page_id': 'p1',
        'block_ids': ['k1'],
        'markdown': 'More',
      },
    );
    page('p1', ref('p1'));
    remove(false);
    expect(await h['page.append']!.undo(r), UndoOutcome.skippedChanged);
    verify(
      () => gw.removeBlocksIfUnchanged(
        'p1',
        blockIds: ['k1'],
        padIds: [],
        expectedMarkdown: 'More',
      ),
    ).called(1);
    page('p1', ref('p1', editable: false));
    expect(await h['page.append']!.undo(r), UndoOutcome.skippedChanged);
    page('p1', null);
    expect(await h['page.append']!.undo(r), UndoOutcome.skippedGone);
    verifyNever(
      () => gw.removeBlocksIfUnchanged(
        any(),
        blockIds: any(named: 'blockIds'),
        padIds: any(named: 'padIds'),
        expectedMarkdown: any(named: 'expectedMarkdown'),
      ),
    );
  });

  test('apply refuses a locked, missing or non-document page before writing',
      () async {
    for (final r in [
      ref('p1', editable: false),
      null,
      ref('p1', layout: 'grid'),
    ]) {
      page('p1', r);
      await expectLater(
        h['page.append']!.apply(append({}), ApplyScope({})),
        throwsStateError,
      );
    }
    for (final r in [ref('s1', editable: false), null]) {
      page('s1', r);
      await expectLater(
        h['page.create']!.apply(create({}), ApplyScope({})),
        throwsStateError,
      );
    }
    verifyNever(() => gw.append(any(), any()));
    verifyNever(() => gw.createPage(any(), any(), any()));
  });

  test('validate rules', () {
    String? v(AssistAction a) => h[a.type]!.validate(a, scope);
    expect(v(create({})), isNull);
    expect(v(create({'parent_id': 'p1'})), isNull);
    expect(v(create({'parent_id': 'zz'})), isNotNull, reason: 'unknown');
    expect(v(create({'parent_id': 'new:1'})), isNotNull, reason: 'unbound');
    expect(v(create({'parent_id': 'p2'})), isNotNull, reason: 'locked parent');
    expect(v(create({'name': '  '})), isNotNull);
    expect(v(create({'name': 'a\nb'})), isNotNull);
    expect(v(create({'name': 'x' * 121})), isNotNull);
    expect(v(create({'name': ' ${'x' * 120} '})), isNull);
    expect(v(create({'content': ''})), isNotNull);
    expect(v(create({'content': 5})), isNotNull);
    expect(v(create({'content': 'x' * 20001})), isNotNull);
    expect(v(create({'content': 'x' * 20000})), isNull);

    expect(v(append({})), isNull);
    expect(v(append({'page_id': 'p2'})), isNotNull, reason: 'locked');
    expect(v(append({'page_id': 'g1'})), isNotNull, reason: 'grid');
    expect(v(append({'page_id': 's1'})), isNotNull, reason: 'space');
    expect(v(append({'page_id': 'zz'})), isNotNull);
    expect(v(append({'content': ' '})), isNotNull);
    expect(v(append({'content': 'x' * 20001})), isNotNull);

    // Parents made earlier in the proposal: pages, boards, databases only.
    scope.knownIds.add('k1'); // a card: known, but not a page
    expect(v(create({'parent_id': 'k1'})), isNotNull);
    scope.boundTemps.addAll(['new:1', 'new:3', 'new:4', 'new:5', 'new:6']);
    expect(v(create({'parent_id': 'new:1'})), isNotNull, reason: 'no record');
    for (final (temp, by, ok) in [
      ('new:1', 'page.create', true),
      ('new:3', 'board.create', true),
      ('new:4', 'database.create', true),
      ('new:5', 'board.card.add', false),
      ('new:6', 'calendar.add', false),
    ]) {
      scope.items[temp] = {'created_by': by};
      expect(v(create({'parent_id': temp})) == null, ok, reason: by);
    }
    expect(
      v(append({'page_id': 'new:1'})),
      isNotNull,
      reason: 'layout unknown',
    );
  });

  test('engine keeps a page.create under a page made earlier in the reply', () {
    final kept = ActionEngine(pageContentHandlers(gw)).filterValid(
      [
        create({'temp_id': 'new:1'}),
        create({'temp_id': 'new:2', 'parent_id': 'new:1'}),
        create({'temp_id': 'new:3', 'parent_id': 'new:9'}),
      ],
      scope: scope,
      stage: AssistStage.pages,
    );
    expect([for (final a in kept) a.tempId], ['new:1', 'new:2']);
  });

  test('previews', () {
    final labels = {'s1': 'Home', 'p1': 'Trip'};
    ActionPreview d(AssistAction a) => h[a.type]!.describe(a, labels);
    final long = 'y' * 300;
    final c = d(create({'content': long}));
    expect(c.text, 'New page: Packing in Home');
    expect(c.after, 'y' * 200);
    expect(c.destructive, isFalse);
    expect(c.editable, ['name', 'content']);
    expect(d(create({'parent_id': 'new:1'})).text, 'New page: Packing');
    final a = d(append({'content': long}));
    expect(a.text, 'Add to Trip');
    expect(a.after, 'y' * 200);
    expect(a.destructive, isFalse);
    expect(a.editable, ['content']);
    expect(d(append({})).after, 'More');
  });

  test('context: tree, texts for up to 3 mentioned documents, labels, locks',
      () async {
    when(() => gw.tree()).thenAnswer(
      (_) async => [
        ref('s1', name: 'Home', layout: 'space'),
        ref('p1', name: 'Trip'),
        ref('p2', name: 'Locked', editable: false),
        ref('g1', name: '', layout: 'grid'),
        ref('d3'),
        ref('d4'),
      ],
    );
    when(() => gw.markdown(any())).thenAnswer(
      (i) async => i.positionalArguments[0] == 'p2'
          ? null
          : '# ${i.positionalArguments[0]}',
    );
    final p = await pageContext(gw, ['g1', 'zz', 'p1', 'p2', 'p1', 'd3', 'd4']);
    expect((p.json['pages'] as List)[1], {
      'id': 'p1',
      'name': 'Trip',
      'parent_id': 's1',
      'layout': 'document',
    });
    expect(p.json['page_texts'], [
      {'id': 'p1', 'markdown': '# p1'},
      {'id': 'd3', 'markdown': '# d3'},
    ]);
    verifyNever(() => gw.markdown('g1'));
    verifyNever(() => gw.markdown('d4'));
    expect(p.ids, {'s1', 'p1', 'p2', 'g1', 'd3', 'd4'});
    expect(p.readOnlyIds, {'p2'});
    expect(p.labels['p1'], 'Trip');
    expect(p.labels['g1'], 'Untitled');
    expect(p.items['s1'], {'layout': 'space', 'parent_id': 's1'});
    expect(p.items['g1'], {'layout': 'grid', 'parent_id': 's1'});
  });
}
