import 'package:appflowy/features/assistant/actions/board_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/board_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockGateway extends Mock implements BoardGateway {}

AssistAction act(String type, Map<String, dynamic> f) =>
    AssistAction(type: type, fields: {'type': type, ...f});

const todo = BoardColumn(id: 'c1', name: 'To do', isDefault: false);
const doing = BoardColumn(id: 'c2', name: 'Doing', isDefault: false);
const none = BoardColumn(id: 'c0', name: 'No Status', isDefault: true);

BoardSnapshot snap({
  List<BoardColumn> cols = const [none, todo, doing],
  List<BoardCard> cards = const [],
  bool editable = true,
}) =>
    BoardSnapshot(
      id: 'b1',
      name: 'Plan',
      columns: cols,
      cards: cards,
      editable: editable,
    );

void main() {
  late _MockGateway gw;
  late Map<String, ActionHandler> h;
  late ValidationScope scope;

  setUp(() {
    gw = _MockGateway();
    h = {for (final x in boardHandlers(gw)) x.type: x};
    scope = ValidationScope(
      knownIds: {'b1', 'c1', 'c2', 'k1'},
      weekStart: DateTime(2026, 10, 19),
      readOnlyIds: {'ro'},
    );
  });

  void board(BoardSnapshot? s) =>
      when(() => gw.board('b1')).thenAnswer((_) async => s);

  test('create binds board and column temp ids, passes exact columns',
      () async {
    when(() => gw.createBoard('Plan', ['To do', 'Doing'])).thenAnswer(
      (_) async => (boardId: 'b9', columnIds: ['c8', 'c9']),
    );
    final s = ApplyScope({});
    final r = await h['board.create']!.apply(
      act('board.create', {
        'temp_id': 'new:1',
        'name': ' Plan ',
        'columns': [
          {'temp_id': 'new:2', 'name': 'To do'},
          {'temp_id': 'new:3', 'name': 'Doing'},
        ],
      }),
      s,
    );
    expect(s.tempIds, {'new:1': 'b9', 'new:2': 'c8', 'new:3': 'c9'});
    expect(r.type, 'board.create');
    expect(r.data['board_id'], 'b9');
  });

  test('create failure binds nothing', () async {
    when(() => gw.createBoard(any(), any())).thenThrow(StateError('x'));
    final s = ApplyScope({});
    await expectLater(
      h['board.create']!.apply(
        act('board.create', {
          'temp_id': 'new:1',
          'name': 'P',
          'columns': [
            {'temp_id': 'new:2', 'name': 'A'},
          ],
        }),
        s,
      ),
      throwsStateError,
    );
    expect(s.tempIds, isEmpty);
  });

  test('undo create deletes board, gone is skipped', () async {
    final rec = UndoRecord(
      type: 'board.create',
      data: {'board_id': 'b1', 'column_ids': <String>[]},
    );
    board(snap());
    when(() => gw.deleteBoard('b1')).thenAnswer((_) async {});
    expect(await h['board.create']!.undo(rec), UndoOutcome.reverted);
    verify(() => gw.deleteBoard('b1')).called(1);
    board(null);
    expect(await h['board.create']!.undo(rec), UndoOutcome.skippedGone);
  });

  test('card.add into a new: column resolves via scope', () async {
    when(() => gw.addCard('b1', 'c7', 'Write')).thenAnswer((_) async => 'k9');
    final s = ApplyScope({'new:2': 'c7'});
    final r = await h['board.card.add']!.apply(
      act('board.card.add', {
        'board_id': 'b1',
        'column_id': 'new:2',
        'temp_id': 'new:5',
        'title': 'Write',
      }),
      s,
    );
    expect(s.tempIds['new:5'], 'k9');
    expect(r.data['card_id'], 'k9');
  });

  test('unbound temp id throws and writes nothing', () async {
    await expectLater(
      h['board.card.add']!.apply(
        act('board.card.add', {
          'board_id': 'b1',
          'column_id': 'new:2',
          'temp_id': 'new:5',
          'title': 'W',
        }),
        ApplyScope({}),
      ),
      throwsStateError,
    );
    verifyNever(() => gw.addCard(any(), any(), any()));
  });

  test('validate rules', () {
    String? v(String t, Map<String, dynamic> f) =>
        h[t]!.validate(act(t, f), scope);
    final create = {
      'temp_id': 'new:1',
      'name': 'P',
      'columns': [
        {'temp_id': 'new:2', 'name': 'A'},
      ],
    };
    expect(v('board.create', create), isNull);
    expect(v('board.create', {...create, 'columns': []}), isNotNull);
    expect(v('board.create', {...create, 'name': 'a\nb'}), isNotNull);
    expect(v('board.create', {...create, 'name': 'x' * 121}), isNotNull);
    expect(v('board.create', {...create, 'name': '  '}), isNotNull);
    expect(
      v(
        'board.column.add',
        {'board_id': 'b1', 'temp_id': 'new:3', 'name': 'X'},
      ),
      isNull,
    );
    expect(
      v(
        'board.column.add',
        {'board_id': 'zz', 'temp_id': 'new:3', 'name': 'X'},
      ),
      isNotNull,
    );
    expect(
      v(
        'board.column.add',
        {'board_id': 'ro', 'temp_id': 'new:3', 'name': 'X'},
      ),
      isNotNull,
    );
    scope.boundTemps.addAll(['new:1', 'new:2']);
    expect(
      v('board.card.add', {
        'board_id': 'new:1',
        'column_id': 'new:2',
        'temp_id': 'new:4',
        'title': 'T',
      }),
      isNull,
    );
    expect(
      v('board.card.update', {'board_id': 'b1', 'card_id': 'k1'}),
      isNotNull,
    );
    expect(
      v('board.card.update', {
        'board_id': 'b1',
        'card_id': 'k1',
        'column_id': 'c2',
      }),
      isNull,
    );
    expect(
      v('board.card.update', {'board_id': 'b1', 'card_id': 'k1', 'title': ''}),
      isNotNull,
    );
    expect(
      v('board.card.remove', {'board_id': 'b1', 'card_id': 'nope'}),
      isNotNull,
    );
    expect(
      v('board.column.remove', {'board_id': 'b1', 'column_id': 'c1'}),
      isNull,
    );
    expect(
      v(
        'board.column.rename',
        {'board_id': 'b1', 'column_id': 'c1', 'name': ''},
      ),
      isNotNull,
    );
  });

  test('previews', () {
    final labels = {
      'b1': 'Plan',
      'c1': 'To do',
      'c2': 'Doing',
      'c1#cards': 'A, B',
      'k1': 'Write',
      'k1#column': 'To do',
    };
    ActionPreview d(String t, Map<String, dynamic> f) =>
        h[t]!.describe(act(t, f), labels);
    expect(
      d('board.create', {
        'name': 'Plan',
        'columns': [
          {'name': 'To do'},
          {'name': 'Doing'},
        ],
      }).text,
      'New board: Plan (To do, Doing)',
    );
    expect(
      d('board.column.add', {'board_id': 'b1', 'name': 'Done'}).text,
      'Add column: Done',
    );
    final rn = d('board.column.rename', {
      'board_id': 'b1',
      'column_id': 'c1',
      'name': 'Later',
    });
    expect(rn.text, 'Rename column');
    expect([rn.before, rn.after], ['To do', 'Later']);
    final rm = d('board.column.remove', {'board_id': 'b1', 'column_id': 'c1'});
    expect(rm.text, 'Remove column: To do — moves A, B to No status');
    expect(rm.destructive, true);
    expect(
      d('board.column.remove', {'board_id': 'b1', 'column_id': 'c2'}).text,
      'Remove column: Doing',
    );
    expect(
      d('board.card.add', {'board_id': 'b1', 'title': 'Hi'}).text,
      'Add card: Hi',
    );
    final mv = d('board.card.update', {
      'board_id': 'b1',
      'card_id': 'k1',
      'column_id': 'c2',
    });
    expect(mv.text, 'Change card: Write');
    expect([mv.before, mv.after], ['To do', 'Doing']);
    final rc = d('board.card.remove', {'board_id': 'b1', 'card_id': 'k1'});
    expect(rc.text, 'Remove card: Write');
    expect(rc.destructive, true);
  });

  test('column.add undo: removes empty, keeps one holding cards', () async {
    when(() => gw.addColumn('b1', 'Done')).thenAnswer((_) async => 'c5');
    final r = await h['board.column.add']!.apply(
      act('board.column.add', {
        'board_id': 'b1',
        'temp_id': 'new:3',
        'name': 'Done',
      }),
      ApplyScope({}),
    );
    const done = BoardColumn(id: 'c5', name: 'Done', isDefault: false);
    when(() => gw.removeColumn('b1', 'c5')).thenAnswer((_) async {});
    board(snap(cols: [none, done]));
    expect(await h['board.column.add']!.undo(r), UndoOutcome.reverted);
    board(
      snap(
        cols: [none, done],
        cards: [const BoardCard(id: 'k', title: 'x', columnId: 'c5')],
      ),
    );
    expect(await h['board.column.add']!.undo(r), UndoOutcome.skippedChanged);
    board(snap());
    expect(await h['board.column.add']!.undo(r), UndoOutcome.skippedGone);
  });

  test('column.rename undo only when name unchanged since', () async {
    board(snap());
    when(() => gw.renameColumn(any(), any(), any())).thenAnswer((_) async {});
    final r = await h['board.column.rename']!.apply(
      act('board.column.rename', {
        'board_id': 'b1',
        'column_id': 'c1',
        'name': 'Later',
      }),
      ApplyScope({}),
    );
    verify(() => gw.renameColumn('b1', 'c1', 'Later')).called(1);
    board(
      snap(
        cols: [
          none,
          const BoardColumn(id: 'c1', name: 'Mine', isDefault: false),
        ],
      ),
    );
    expect(await h['board.column.rename']!.undo(r), UndoOutcome.skippedChanged);
    board(
      snap(
        cols: [
          none,
          const BoardColumn(id: 'c1', name: 'Later', isDefault: false),
        ],
      ),
    );
    expect(await h['board.column.rename']!.undo(r), UndoOutcome.reverted);
    verify(() => gw.renameColumn('b1', 'c1', 'To do')).called(1);
  });

  test('column.remove undo re-adds and moves cards back, idempotent', () async {
    board(
      snap(
        cards: [
          const BoardCard(id: 'k1', title: 'A', columnId: 'c1'),
          const BoardCard(id: 'k2', title: 'B', columnId: 'c1'),
        ],
      ),
    );
    when(() => gw.removeColumn('b1', 'c1')).thenAnswer((_) async {});
    final r = await h['board.column.remove']!.apply(
      act('board.column.remove', {'board_id': 'b1', 'column_id': 'c1'}),
      ApplyScope({}),
    );
    // Column gone, cards fell into the default group; k2 was moved elsewhere.
    board(
      snap(
        cols: [none, doing],
        cards: [
          const BoardCard(id: 'k1', title: 'A', columnId: 'c0'),
          const BoardCard(id: 'k2', title: 'B', columnId: 'c2'),
        ],
      ),
    );
    when(() => gw.addColumn('b1', 'To do')).thenAnswer((_) async => 'c7');
    when(
      () => gw.updateCard(
        any(),
        any(),
        title: any(named: 'title'),
        columnId: any(named: 'columnId'),
      ),
    ).thenAnswer((_) async {});
    expect(await h['board.column.remove']!.undo(r), UndoOutcome.reverted);
    verify(() => gw.updateCard('b1', 'k1', columnId: 'c7')).called(1);
    verifyNever(() => gw.updateCard('b1', 'k2', columnId: 'c7'));
    expect(r.data['restored_id'], 'c7');
    expect(await h['board.column.remove']!.undo(r), UndoOutcome.reverted);
    verify(() => gw.addColumn('b1', 'To do')).called(1);
  });

  test('column.remove undo skipped when a column exists again', () async {
    final r = UndoRecord(
      type: 'board.column.remove',
      data: {
        'board_id': 'b1',
        'column_id': 'c1',
        'name': 'To do',
        'card_ids': <String>[],
      },
    );
    board(snap());
    expect(await h['board.column.remove']!.undo(r), UndoOutcome.skippedChanged);
  });

  test('card.add undo: unchanged removes, changed/gone skipped', () async {
    when(() => gw.addCard('b1', 'c1', 'Write')).thenAnswer((_) async => 'k9');
    final r = await h['board.card.add']!.apply(
      act('board.card.add', {
        'board_id': 'b1',
        'column_id': 'c1',
        'temp_id': 'new:5',
        'title': 'Write',
      }),
      ApplyScope({}),
    );
    when(() => gw.removeCard('b1', 'k9')).thenAnswer((_) async {});
    board(
      snap(
        cards: [const BoardCard(id: 'k9', title: 'Write', columnId: 'c1')],
      ),
    );
    expect(await h['board.card.add']!.undo(r), UndoOutcome.reverted);
    board(
      snap(cards: [const BoardCard(id: 'k9', title: 'Wr', columnId: 'c1')]),
    );
    expect(await h['board.card.add']!.undo(r), UndoOutcome.skippedChanged);
    board(
      snap(
        cards: [const BoardCard(id: 'k9', title: 'Write', columnId: 'c2')],
      ),
    );
    expect(await h['board.card.add']!.undo(r), UndoOutcome.skippedChanged);
    board(snap());
    expect(await h['board.card.add']!.undo(r), UndoOutcome.skippedGone);
  });

  test('card.update undo skipped when renamed since', () async {
    board(
      snap(
        cards: [const BoardCard(id: 'k1', title: 'Write', columnId: 'c1')],
      ),
    );
    when(
      () => gw.updateCard(
        any(),
        any(),
        title: any(named: 'title'),
        columnId: any(named: 'columnId'),
      ),
    ).thenAnswer((_) async {});
    final r = await h['board.card.update']!.apply(
      act('board.card.update', {
        'board_id': 'b1',
        'card_id': 'k1',
        'title': 'Draft',
        'column_id': 'c2',
      }),
      ApplyScope({}),
    );
    verify(() => gw.updateCard('b1', 'k1', title: 'Draft', columnId: 'c2'))
        .called(1);
    board(
      snap(
        cards: [const BoardCard(id: 'k1', title: 'Mine', columnId: 'c2')],
      ),
    );
    expect(await h['board.card.update']!.undo(r), UndoOutcome.skippedChanged);
    board(
      snap(
        cards: [const BoardCard(id: 'k1', title: 'Draft', columnId: 'c2')],
      ),
    );
    expect(await h['board.card.update']!.undo(r), UndoOutcome.reverted);
    verify(() => gw.updateCard('b1', 'k1', title: 'Write', columnId: 'c1'))
        .called(1);
    board(snap());
    expect(await h['board.card.update']!.undo(r), UndoOutcome.skippedGone);
  });

  test('card.remove undo re-adds once, into default if column is gone',
      () async {
    board(
      snap(
        cards: [const BoardCard(id: 'k1', title: 'Write', columnId: 'c1')],
      ),
    );
    when(() => gw.removeCard('b1', 'k1')).thenAnswer((_) async {});
    final r = await h['board.card.remove']!.apply(
      act('board.card.remove', {'board_id': 'b1', 'card_id': 'k1'}),
      ApplyScope({}),
    );
    board(snap(cols: [none, doing]));
    when(() => gw.addCard('b1', 'c0', 'Write')).thenAnswer((_) async => 'k8');
    expect(await h['board.card.remove']!.undo(r), UndoOutcome.reverted);
    expect(r.data['restored_id'], 'k8');
    expect(await h['board.card.remove']!.undo(r), UndoOutcome.reverted);
    verify(() => gw.addCard('b1', 'c0', 'Write')).called(1);
  });

  test('context: all boards, detailed columns/cards, labels, read-only',
      () async {
    when(() => gw.boards()).thenAnswer(
      (_) async => [(id: 'b1', name: 'Plan'), (id: 'b2', name: 'Other')],
    );
    board(
      snap(
        cards: [
          const BoardCard(id: 'k1', title: 'A', columnId: 'c1'),
          const BoardCard(id: 'k2', title: 'B', columnId: 'c1'),
        ],
      ),
    );
    when(() => gw.board('b2')).thenAnswer(
      (_) async => const BoardSnapshot(
        id: 'b2',
        name: 'Other',
        columns: [],
        cards: [],
        editable: false,
      ),
    );
    final p = await boardContext(gw, ['b1']);
    final bs = p.json['boards'] as List;
    expect(bs[1], {'id': 'b2', 'name': 'Other'});
    expect((bs[0] as Map)['cards'], [
      {'id': 'k1', 'title': 'A', 'column_id': 'c1'},
      {'id': 'k2', 'title': 'B', 'column_id': 'c1'},
    ]);
    expect(p.ids, {'b1', 'b2', 'c0', 'c1', 'c2', 'k1', 'k2'});
    expect(p.labels['c1'], 'To do');
    expect(p.labels['k1'], 'A');
    expect(p.labels['c1#cards'], 'A, B');
    expect(p.labels['k1#column'], 'To do');
    final p2 = await boardContext(gw, ['b1', 'b2']);
    expect(p2.readOnlyIds, {'b2'});
  });
}
