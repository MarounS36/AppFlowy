import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/board_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';

List<ActionHandler> boardHandlers(BoardGateway gw) => [
      _Create(gw),
      _ColumnAdd(gw),
      _ColumnRename(gw),
      _ColumnRemove(gw),
      _CardAdd(gw),
      _CardUpdate(gw),
      _CardRemove(gw),
    ];

String? _text(Object? t, String what) {
  if (t is! String || t.trim().isEmpty) return '$what is empty';
  if (t.trim().length > 120 || t.contains(RegExp(r'[\r\n]'))) {
    return '$what is too long';
  }
  return null;
}

String _trim(Object? v) => (v as String).trim();

abstract class _Base implements ActionHandler {
  _Base(this.gw);
  final BoardGateway gw;

  @override
  AssistStage get stage => AssistStage.workspace;

  /// Each key in [keys] must be a known (or earlier-created) id; the board
  /// must be editable.
  String? checkIds(AssistAction a, ValidationScope scope, List<String> keys) {
    final f = a.fields;
    for (final k in keys) {
      final v = f[k];
      if (v is! String ||
          !(scope.knownIds.contains(v) || scope.boundTemps.contains(v))) {
        return 'Unknown $k';
      }
    }
    if (scope.readOnlyIds.contains(f['board_id'])) {
      return 'Board is read-only';
    }
    return null;
  }

  String label(Map<String, String> labels, Object? id, [String? fallback]) =>
      labels[id] ?? fallback ?? '';

  Future<BoardSnapshot?> snapshot(String id) => gw.board(id);

  /// The board, or throws if it is gone or not a single-select board. Call
  /// before any write.
  Future<BoardSnapshot> mustBoard(String id) async {
    final s = await gw.board(id);
    if (s == null || !s.editable) throw StateError("Board can't be edited");
    return s;
  }

  bool hasName(BoardSnapshot s, String name, {String? except}) => s.columns.any(
        (c) =>
            c.id != except &&
            c.name.trim().toLowerCase() == name.trim().toLowerCase(),
      );

  BoardCard? card(BoardSnapshot s, String id) =>
      s.cards.where((c) => c.id == id).firstOrNull;

  BoardColumn? column(BoardSnapshot s, String id) =>
      s.columns.where((c) => c.id == id).firstOrNull;
}

class _Create extends _Base {
  _Create(super.gw);

  @override
  String get type => 'board.create';

  List<Map> _cols(AssistAction a) => [
        for (final c in (a.fields['columns'] as List? ?? const []))
          if (c is Map) c,
      ];

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final err = _text(a.fields['name'], 'Name');
    if (err != null) return err;
    final cols = _cols(a);
    if (cols.isEmpty) return 'A board needs at least one column';
    final seen = <String>{};
    for (final c in cols) {
      final e = _text(c['name'], 'Column name');
      if (e != null) return e;
      if (!seen.add(_trim(c['name']).toLowerCase())) {
        return 'Duplicate column name';
      }
    }
    return null;
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'New board: ${a.fields['name']} '
            '(${_cols(a).map((c) => c['name']).join(', ')})',
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final cols = _cols(a);
    final r = await gw.createBoard(
      _trim(a.fields['name']),
      [for (final c in cols) _trim(c['name'])],
    );
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, r.boardId);
    for (var i = 0; i < cols.length; i++) {
      final t = cols[i]['temp_id'] as String?;
      if (t != null) scope.bind(t, r.columnIds[i]);
    }
    return UndoRecord(
      type: type,
      data: {'board_id': r.boardId, 'column_ids': r.columnIds},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['board_id'] as String;
    if (await snapshot(id) == null) return UndoOutcome.skippedGone;
    await gw.deleteBoard(id);
    return UndoOutcome.reverted;
  }
}

class _ColumnAdd extends _Base {
  _ColumnAdd(super.gw);

  @override
  String get type => 'board.column.add';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      checkIds(a, scope, ['board_id']) ?? _text(a.fields['name'], 'Name');

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Add column: ${a.fields['name']}',
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final board = scope.resolve(a.fields['board_id'] as String);
    final name = _trim(a.fields['name']);
    if (hasName(await mustBoard(board), name)) {
      throw StateError('A column named $name already exists');
    }
    final id = await gw.addColumn(board, name);
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, id);
    return UndoRecord(
      type: type,
      data: {'board_id': board, 'column_id': id},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final board = r.data['board_id'] as String;
    final id = r.data['column_id'] as String;
    final s = await snapshot(board);
    if (s == null || column(s, id) == null) return UndoOutcome.skippedGone;
    if (s.cards.any((c) => c.columnId == id)) return UndoOutcome.skippedChanged;
    await gw.removeColumn(board, id);
    return UndoOutcome.reverted;
  }
}

class _ColumnRename extends _Base {
  _ColumnRename(super.gw);

  @override
  String get type => 'board.column.rename';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      checkIds(a, scope, ['board_id', 'column_id']) ??
      _text(a.fields['name'], 'Name');

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Rename column',
        before: label(labels, a.fields['column_id']),
        after: a.fields['name'] as String?,
        editable: const ['name'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final board = scope.resolve(a.fields['board_id'] as String);
    final id = scope.resolve(a.fields['column_id'] as String);
    final s = await mustBoard(board);
    final col = column(s, id) ?? (throw StateError('Column not found'));
    if (col.isDefault) throw StateError('The default column cannot be renamed');
    final name = _trim(a.fields['name']);
    if (hasName(s, name, except: id)) {
      throw StateError('A column named $name already exists');
    }
    await gw.renameColumn(board, id, name);
    return UndoRecord(
      type: type,
      data: {
        'board_id': board,
        'column_id': id,
        'before': col.name,
        'after': name,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final board = r.data['board_id'] as String;
    final id = r.data['column_id'] as String;
    final s = await snapshot(board);
    final col = s == null ? null : column(s, id);
    if (col == null) return UndoOutcome.skippedGone;
    if (col.name != r.data['after']) return UndoOutcome.skippedChanged;
    await gw.renameColumn(board, id, r.data['before'] as String);
    return UndoOutcome.reverted;
  }
}

class _ColumnRemove extends _Base {
  _ColumnRemove(super.gw);

  @override
  String get type => 'board.column.remove';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      checkIds(a, scope, ['board_id', 'column_id']);

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final id = a.fields['column_id'];
    final cards = labels['$id#cards'] ?? '';
    final home = labels['${a.fields['board_id']}#default'] ?? 'No status';
    return ActionPreview(
      text: 'Remove column: ${label(labels, id)}'
          '${cards.isEmpty ? '' : ' — moves $cards to $home'}',
      destructive: true,
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final board = scope.resolve(a.fields['board_id'] as String);
    final id = scope.resolve(a.fields['column_id'] as String);
    final s = await mustBoard(board);
    final col = column(s, id) ?? (throw StateError('Column not found'));
    if (col.isDefault) throw StateError('The default column cannot be removed');
    final moved = await gw.removeColumn(board, id);
    return UndoRecord(
      type: type,
      data: {
        'board_id': board,
        'column_id': id,
        'name': col.name,
        'card_ids': moved,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    // Idempotent: a repeated undo must not add a second column.
    if (r.data['restored_id'] != null) return UndoOutcome.reverted;
    final board = r.data['board_id'] as String;
    final s = await snapshot(board);
    if (s == null) return UndoOutcome.skippedGone;
    if (column(s, r.data['column_id'] as String) != null) {
      return UndoOutcome.skippedChanged;
    }
    final newId = await gw.addColumn(board, r.data['name'] as String);
    r.data['restored_id'] = newId;
    final home = s.columns.where((c) => c.isDefault).firstOrNull?.id;
    final ids = (r.data['card_ids'] as List).cast<String>();
    for (final c in s.cards) {
      if (ids.contains(c.id) && c.columnId == home) {
        await gw.updateCard(board, c.id, columnId: newId);
      }
    }
    return UndoOutcome.reverted;
  }
}

class _CardAdd extends _Base {
  _CardAdd(super.gw);

  @override
  String get type => 'board.card.add';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      checkIds(a, scope, ['board_id', 'column_id']) ??
      _text(a.fields['title'], 'Title');

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Add card: ${a.fields['title']}',
        editable: const ['title'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final board = scope.resolve(a.fields['board_id'] as String);
    final col = scope.resolve(a.fields['column_id'] as String);
    final title = _trim(a.fields['title']);
    await mustBoard(board);
    final id = await gw.addCard(board, col, title);
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, id);
    return UndoRecord(
      type: type,
      data: {
        'board_id': board,
        'card_id': id,
        'column_id': col,
        'title': title,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final board = r.data['board_id'] as String;
    final id = r.data['card_id'] as String;
    final s = await snapshot(board);
    final c = s == null ? null : card(s, id);
    if (c == null) return UndoOutcome.skippedGone;
    if (c.title != r.data['title'] || c.columnId != r.data['column_id']) {
      return UndoOutcome.skippedChanged;
    }
    await gw.removeCard(board, id);
    return UndoOutcome.reverted;
  }
}

class _CardUpdate extends _Base {
  _CardUpdate(super.gw);

  @override
  String get type => 'board.card.update';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final f = a.fields;
    if (f['title'] == null && f['column_id'] == null) {
      return 'Nothing to change';
    }
    return checkIds(a, scope, [
          'board_id',
          'card_id',
          if (f['column_id'] != null) 'column_id',
        ]) ??
        (f['title'] == null ? null : _text(f['title'], 'Title'));
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final f = a.fields;
    final oldTitle = label(labels, f['card_id']);
    final oldCol = label(labels, '${f['card_id']}#column');
    final title = f['title'] as String?;
    final col = f['column_id'] as String?;
    final newCol = col == null ? null : label(labels, col);
    return ActionPreview(
      text: 'Change card: $oldTitle',
      before:
          [if (title != null) oldTitle, if (col != null) oldCol].join(' · '),
      after: [if (title != null) title, if (newCol != null) newCol].join(' · '),
      editable: [if (title != null) 'title'],
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final f = a.fields;
    final board = scope.resolve(f['board_id'] as String);
    final id = scope.resolve(f['card_id'] as String);
    final col =
        f['column_id'] == null ? null : scope.resolve(f['column_id'] as String);
    final title = f['title'] == null ? null : _trim(f['title']);
    final cur = card(await mustBoard(board), id) ??
        (throw StateError('Card not found'));
    await gw.updateCard(board, id, title: title, columnId: col);
    return UndoRecord(
      type: type,
      data: {
        'board_id': board,
        'card_id': id,
        'before': {'title': cur.title, 'column_id': cur.columnId},
        'after': {
          'title': title ?? cur.title,
          'column_id': col ?? cur.columnId,
        },
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final board = r.data['board_id'] as String;
    final id = r.data['card_id'] as String;
    final s = await snapshot(board);
    final c = s == null ? null : card(s, id);
    if (c == null) return UndoOutcome.skippedGone;
    final before = Map<String, dynamic>.from(r.data['before'] as Map);
    final after = Map<String, dynamic>.from(r.data['after'] as Map);
    if (c.title != after['title'] || c.columnId != after['column_id']) {
      return UndoOutcome.skippedChanged;
    }
    await gw.updateCard(
      board,
      id,
      title: before['title'] as String,
      columnId: before['column_id'] as String,
    );
    return UndoOutcome.reverted;
  }
}

/// Known limit: undoing a remove re-adds the card under a NEW id.
class _CardRemove extends _Base {
  _CardRemove(super.gw);

  @override
  String get type => 'board.card.remove';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      checkIds(a, scope, ['board_id', 'card_id']);

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Remove card: ${label(labels, a.fields['card_id'])}',
        destructive: true,
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final board = scope.resolve(a.fields['board_id'] as String);
    final id = scope.resolve(a.fields['card_id'] as String);
    final cur = card(await mustBoard(board), id) ??
        (throw StateError('Card not found'));
    await gw.removeCard(board, id);
    return UndoRecord(
      type: type,
      data: {
        'board_id': board,
        'card_id': id,
        'title': cur.title,
        'column_id': cur.columnId,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    if (r.data['restored_id'] != null) return UndoOutcome.reverted;
    final board = r.data['board_id'] as String;
    final s = await snapshot(board);
    if (s == null) return UndoOutcome.skippedGone;
    if (card(s, r.data['card_id'] as String) != null) {
      return UndoOutcome.skippedChanged;
    }
    final col = column(s, r.data['column_id'] as String) ??
        s.columns.where((c) => c.isDefault).firstOrNull ??
        (throw StateError('No column to restore into'));
    r.data['restored_id'] =
        await gw.addCard(board, col.id, r.data['title'] as String);
    return UndoOutcome.reverted;
  }
}

/// All boards by name; up to 3 [detailed] ones with columns and cards.
Future<ContextPart> boardContext(
  BoardGateway gw,
  List<String> detailedBoardIds,
) async {
  final all = await gw.boards();
  final detailed = detailedBoardIds.take(3).toSet();
  final json = <Map<String, dynamic>>[];
  final labels = <String, String>{};
  final ids = <String>{};
  final readOnly = <String>{};
  for (final b in all) {
    ids.add(b.id);
    labels[b.id] = b.name;
    final entry = <String, dynamic>{'id': b.id, 'name': b.name};
    final s = detailed.contains(b.id) ? await gw.board(b.id) : null;
    if (s != null) {
      if (!s.editable) readOnly.add(b.id);
      final names = {for (final c in s.columns) c.id: c.name};
      entry['columns'] = [
        for (final c in s.columns) {'id': c.id, 'name': c.name},
      ];
      entry['cards'] = [
        for (final c in s.cards)
          {'id': c.id, 'title': c.title, 'column_id': c.columnId},
      ];
      for (final c in s.columns) {
        ids.add(c.id);
        labels[c.id] = c.name;
        if (c.isDefault) labels['${b.id}#default'] = c.name;
        final titles =
            s.cards.where((k) => k.columnId == c.id).map((k) => k.title);
        if (titles.isNotEmpty) labels['${c.id}#cards'] = titles.join(', ');
      }
      for (final c in s.cards) {
        ids.add(c.id);
        labels[c.id] = c.title;
        labels['${c.id}#column'] = names[c.columnId] ?? '';
      }
    }
    json.add(entry);
  }
  return ContextPart(
    json: {'boards': json},
    labels: labels,
    ids: ids,
    readOnlyIds: readOnly,
  );
}
