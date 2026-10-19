import 'dart:convert';

import 'package:appflowy/features/assistant/gateways/space.dart';
import 'package:appflowy/plugins/database/application/cell/cell_controller.dart';
import 'package:appflowy/plugins/database/application/field/field_info.dart';
import 'package:appflowy/plugins/database/application/row/row_service.dart';
import 'package:appflowy/plugins/database/domain/cell_service.dart';
import 'package:appflowy/plugins/database/domain/database_view_service.dart';
import 'package:appflowy/plugins/database/domain/field_service.dart';
import 'package:appflowy/plugins/database/domain/group_service.dart';
import 'package:appflowy/plugins/trash/application/trash_service.dart';
import 'package:appflowy/workspace/application/view/view_service.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-database2/protobuf.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';

class BoardColumn {
  const BoardColumn({
    required this.id,
    required this.name,
    required this.isDefault,
  });

  final String id, name;

  /// The "No field" group; it can't be renamed or removed.
  final bool isDefault;
}

class BoardCard {
  const BoardCard({
    required this.id,
    required this.title,
    required this.columnId,
  });

  final String id, title, columnId;
}

class BoardSnapshot {
  const BoardSnapshot({
    required this.id,
    required this.name,
    required this.columns,
    required this.cards,
    required this.editable,
  });

  final String id, name;
  final List<BoardColumn> columns;
  final List<BoardCard> cards;

  /// False when the board isn't grouped by a single-select field.
  final bool editable;
}

/// Thin wrapper over the existing folder/database services; not unit-tested.
/// Every failed backend call throws its `FlowyError`.
class BoardGateway {
  Future<List<({String id, String name})>> boards() async {
    final views = (await ViewBackendService.getAllViews()).getOrThrow().items;
    return [
      for (final v in views)
        if (v.layout == ViewLayoutPB.Board) (id: v.id, name: v.name),
    ];
  }

  /// Null when the board no longer exists.
  Future<BoardSnapshot?> board(String boardId, {int cardCap = 200}) async {
    final name = (await boards())
        .where((b) => b.id == boardId)
        .map((b) => b.name)
        .firstOrNull;
    if (name == null) return null;
    final groups = await _groups(boardId);
    if (groups.isEmpty) {
      return BoardSnapshot(
        id: boardId,
        name: name,
        columns: const [],
        cards: const [],
        editable: false,
      );
    }
    final field = await _groupField(boardId, groups.first.fieldId);
    final editable = field.fieldType == FieldType.SingleSelect;
    final options = {
      if (editable)
        for (final o
            in SingleSelectTypeOptionPB.fromBuffer(field.typeOptionData)
                .options)
          o.id: o.name,
    };
    final columns = <BoardColumn>[];
    final cards = <BoardCard>[];
    final primary = (await FieldBackendService.getPrimaryField(viewId: boardId))
        .getOrThrow();
    for (final g in groups) {
      columns.add(
        BoardColumn(
          id: g.groupId,
          name: g.isDefault
              ? 'No ${field.name}'
              : options[g.groupId] ?? g.groupId,
          isDefault: g.isDefault,
        ),
      );
      for (final r in g.rows) {
        if (cards.length >= cardCap) break;
        final cell = (await CellBackendService.getCell(
          viewId: boardId,
          cellContext: CellContext(fieldId: primary.id, rowId: r.id),
        ))
            .getOrThrow();
        cards.add(
          BoardCard(
            id: r.id,
            title: utf8.decode(cell.data),
            columnId: g.groupId,
          ),
        );
      }
    }
    return BoardSnapshot(
      id: boardId,
      name: name,
      columns: columns,
      cards: cards,
      editable: editable,
    );
  }

  Future<List<GroupPB>> _groups(String boardId) async =>
      (await DatabaseViewBackendService(viewId: boardId).loadGroups())
          .getOrThrow()
          .items
          .toList();

  Future<FieldPB> _groupField(String boardId, String fieldId) async =>
      (await FieldBackendService.getFields(viewId: boardId))
          .getOrThrow()
          .firstWhere((f) => f.id == fieldId);

  /// Space board with exactly [columns] (+ the default group) and no cards.
  /// Deletes the board again if any step fails.
  Future<({String boardId, List<String> columnIds})> createBoard(
    String name,
    List<String> columns,
  ) async {
    final view = (await ViewBackendService.createView(
      layoutType: ViewLayoutPB.Board,
      parentViewId: await currentSpaceId(),
      name: name,
    ))
        .getOrThrow();
    try {
      final groups = await _groups(view.id);
      final rows = [for (final g in groups) ...g.rows.map((r) => r.id)];
      if (rows.isNotEmpty) {
        (await RowBackendService.deleteRows(view.id, rows)).getOrThrow();
      }
      for (final g in groups.where((g) => !g.isDefault)) {
        (await GroupBackendService(view.id).deleteGroup(groupId: g.groupId))
            .getOrThrow();
      }
      final ids = <String>[];
      for (final c in columns) {
        ids.add(await addColumn(view.id, c));
      }
      return (boardId: view.id, columnIds: ids);
    } catch (_) {
      final r = await ViewBackendService.deleteView(viewId: view.id);
      r.onFailure((e) => Log.warn('Could not clean up board ${view.id}: $e'));
      rethrow;
    }
  }

  Future<void> deleteBoard(String boardId) async =>
      (await ViewBackendService.deleteView(viewId: boardId)).getOrThrow();

  Future<void> restoreBoard(String boardId) async =>
      (await TrashService.putback(boardId)).getOrThrow();

  Future<Set<String>> _optionIds(String boardId) async {
    final groups = await _groups(boardId);
    final field = await _groupField(boardId, groups.first.fieldId);
    return {
      for (final o
          in SingleSelectTypeOptionPB.fromBuffer(field.typeOptionData).options)
        o.id,
    };
  }

  Future<String> addColumn(String boardId, String name) async {
    final before = await _optionIds(boardId);
    (await GroupBackendService(boardId).createGroup(name: name)).getOrThrow();
    final groups = await _groups(boardId);
    final field = await _groupField(boardId, groups.first.fieldId);
    return SingleSelectTypeOptionPB.fromBuffer(field.typeOptionData)
        .options
        .firstWhere((o) => o.name == name && !before.contains(o.id))
        .id;
  }

  Future<void> renameColumn(
    String boardId,
    String columnId,
    String name,
  ) async =>
      (await GroupBackendService(boardId)
              .updateGroup(groupId: columnId, name: name))
          .getOrThrow();

  /// AppFlowy deletes a group's rows with the group, so every card is first
  /// moved to the default group. Returns the moved card ids; on failure the
  /// moved cards go back and the error is rethrown.
  Future<List<String>> removeColumn(String boardId, String columnId) async {
    final groups = await _groups(boardId);
    final target = groups.firstWhere((g) => g.isDefault).groupId;
    final ids = [
      for (final g in groups.where((g) => g.groupId == columnId))
        ...g.rows.map((r) => r.id),
    ];
    final service = DatabaseViewBackendService(viewId: boardId);
    final moved = <String>[];
    try {
      for (final id in ids) {
        (await service.moveGroupRow(
          fromRowId: id,
          fromGroupId: columnId,
          toGroupId: target,
        ))
            .getOrThrow();
        moved.add(id);
      }
      (await GroupBackendService(boardId).deleteGroup(groupId: columnId))
          .getOrThrow();
    } catch (_) {
      for (final id in moved) {
        try {
          await service.moveGroupRow(
            fromRowId: id,
            fromGroupId: target,
            toGroupId: columnId,
          );
        } catch (_) {}
      }
      rethrow;
    }
    return ids;
  }

  Future<String> addCard(String boardId, String columnId, String title) async {
    final primary = (await FieldBackendService.getPrimaryField(viewId: boardId))
        .getOrThrow();
    final row = (await RowBackendService.createRow(
      viewId: boardId,
      groupId: columnId,
      withCells: (b) => b.insertText(FieldInfo.initial(primary), title),
    ))
        .getOrThrow();
    return row.id;
  }

  /// Title and/or column. If the move fails after the title was written, the
  /// title is put back before rethrowing.
  Future<void> updateCard(
    String boardId,
    String cardId, {
    String? title,
    String? columnId,
  }) async {
    final cur = (await board(boardId))
            ?.cards
            .where((c) => c.id == cardId)
            .firstOrNull ??
        (throw StateError('Card not found'));
    final primary = (await FieldBackendService.getPrimaryField(viewId: boardId))
        .getOrThrow();
    Future<void> setTitle(String t) async =>
        (await CellBackendService.updateCell(
          viewId: boardId,
          cellContext: CellContext(fieldId: primary.id, rowId: cardId),
          data: t,
        ))
            .getOrThrow();
    final titleChanged = title != null && title != cur.title;
    if (titleChanged) await setTitle(title);
    if (columnId == null || columnId == cur.columnId) return;
    try {
      (await DatabaseViewBackendService(viewId: boardId).moveGroupRow(
        fromRowId: cardId,
        fromGroupId: cur.columnId,
        toGroupId: columnId,
      ))
          .getOrThrow();
    } catch (_) {
      if (titleChanged) {
        try {
          await setTitle(cur.title);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> removeCard(String boardId, String cardId) async =>
      (await RowBackendService.deleteRows(boardId, [cardId])).getOrThrow();
}
