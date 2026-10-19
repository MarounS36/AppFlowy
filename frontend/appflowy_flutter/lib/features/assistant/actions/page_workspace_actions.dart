import 'package:appflowy/features/assistant/actions/page_content_actions.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/page_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';

List<ActionHandler> pageWorkspaceHandlers(PageGateway gw) => [
      _Rename(gw),
      _Move(gw),
      _Duplicate(gw),
      _Favorite(gw),
      _Delete(gw),
    ];

String _label(Map<String, String> labels, Object? id) => labels[id] ?? '';

abstract class _Base implements ActionHandler {
  _Base(this.gw);
  final PageGateway gw;

  @override
  AssistStage get stage => AssistStage.workspace;

  List<String> get editable => const [];

  /// The target must be a known, unlocked page, never a space.
  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final id = a.fields['page_id'];
    final layout = scope.items[id]?['layout'];
    if (!scope.knownIds.contains(id) || layout == null || layout == 'space') {
      return 'Unknown page_id';
    }
    if (scope.readOnlyIds.contains(id)) return 'Page is locked';
    return null;
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: text(a, _label(labels, a.fields['page_id'])),
        editable: editable,
      );

  String text(AssistAction a, String label);

  /// The page, or throws if it is gone or locked. Call before any write.
  Future<PageRef> mustPage(String id) async {
    final p = await gw.page(id);
    if (p == null || !p.editable) throw StateError("Page can't be edited");
    return p;
  }
}

class _Rename extends _Base {
  _Rename(super.gw);

  @override
  String get type => 'page.rename';

  @override
  List<String> get editable => const ['name'];

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final n = a.fields['name'];
    if (n is! String || n.trim().isEmpty) return 'Name is empty';
    if (n.trim().length > 120 || n.contains(RegExp(r'[\r\n]'))) {
      return 'Name is too long';
    }
    return super.validate(a, scope);
  }

  @override
  String text(AssistAction a, String label) => 'Rename page';

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Rename page',
        before: _label(labels, a.fields['page_id']),
        after: a.fields['name'] as String?,
        editable: editable,
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final id = a.fields['page_id'] as String;
    final before = (await mustPage(id)).name;
    final after = (a.fields['name'] as String).trim();
    await gw.rename(id, after);
    return UndoRecord(
      type: type,
      data: {'page_id': id, 'before': before, 'after': after},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['page_id'] as String;
    final p = await gw.page(id);
    if (p == null) return UndoOutcome.skippedGone;
    if (p.name != r.data['after']) return UndoOutcome.skippedChanged;
    await gw.rename(id, r.data['before'] as String);
    return UndoOutcome.reverted;
  }
}

class _Move extends _Base {
  _Move(super.gw);

  @override
  String get type => 'page.move';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final bad = super.validate(a, scope);
    if (bad != null) return bad;
    final parent = a.fields['parent_id'];
    final isTemp = scope.boundTemps.contains(parent) &&
        pageContainerActions.contains(scope.items[parent]?['created_by']);
    if (!isTemp &&
        !(scope.knownIds.contains(parent) &&
            scope.items[parent]?['layout'] != null)) {
      return 'Unknown parent_id';
    }
    // Not under itself or its own descendants.
    var cur = parent;
    for (var i = 0; cur is String && cur.isNotEmpty && i < 500; i++) {
      if (cur == a.fields['page_id']) return "Can't move a page into itself";
      cur = scope.items[cur]?['parent_id'];
    }
    if (scope.readOnlyIds.contains(parent)) return 'Parent is locked';
    final after = a.fields['after_id'];
    if (after != null &&
        (after == a.fields['page_id'] ||
            !scope.knownIds.contains(after) ||
            scope.items[after]?['layout'] == null)) {
      return 'Unknown after_id';
    }
    return null;
  }

  @override
  String text(AssistAction a, String label) => 'Move $label';

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final id = a.fields['page_id'];
    return ActionPreview(
      text: 'Move ${_label(labels, id)}',
      before: _label(labels, '$id#parent'),
      after: _label(labels, a.fields['parent_id']),
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final id = a.fields['page_id'] as String;
    final parent = scope.resolve(a.fields['parent_id'] as String);
    final p = await mustPage(id);
    await mustPage(parent);
    // The live tree may differ from the snapshot the AI saw.
    String? cur = parent;
    for (var i = 0; cur != null && cur.isNotEmpty; i++) {
      if (cur == id || i >= 500) throw StateError("Can't move into itself");
      cur = (await gw.page(cur))?.parentId;
    }
    final prev = await gw.prevSiblingId(id);
    final after = a.fields['after_id'] as String?;
    await gw.move(id, parent, after);
    return UndoRecord(
      type: type,
      data: {
        'page_id': id,
        'before_parent': p.parentId,
        'before_prev': prev,
        'parent': parent,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['page_id'] as String;
    final p = await gw.page(id);
    if (p == null) return UndoOutcome.skippedGone;
    if (p.parentId != r.data['parent']) return UndoOutcome.skippedChanged;
    final back = r.data['before_parent'] as String;
    if (await gw.page(back) == null) return UndoOutcome.skippedChanged;
    final prev = r.data['before_prev'] as String?;
    final sib = prev == null ? null : await gw.page(prev);
    await gw.move(id, back, sib != null && sib.parentId == back ? prev : null);
    return UndoOutcome.reverted;
  }
}

class _Duplicate extends _Base {
  _Duplicate(super.gw);

  @override
  String get type => 'page.duplicate';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final t = a.fields['temp_id'];
    if (t is! String || !t.startsWith('new:')) return 'Missing temp_id';
    return super.validate(a, scope);
  }

  @override
  String text(AssistAction a, String label) => 'Duplicate $label';

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final id = a.fields['page_id'] as String;
    await mustPage(id);
    final copy = await gw.duplicate(id);
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, copy);
    return UndoRecord(type: type, data: {'page_id': copy});
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['page_id'] as String;
    if (await gw.page(id) == null) return UndoOutcome.skippedGone;
    await gw.delete(id);
    return UndoOutcome.reverted;
  }
}

class _Favorite extends _Base {
  _Favorite(super.gw);

  @override
  String get type => 'page.favorite';

  @override
  String? validate(AssistAction a, ValidationScope scope) =>
      a.fields['on'] is! bool
          ? 'on must be true or false'
          : super.validate(a, scope);

  @override
  String text(AssistAction a, String label) => a.fields['on'] == true
      ? 'Add $label to Favorites'
      : 'Remove $label from Favorites';

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final id = a.fields['page_id'] as String;
    final on = a.fields['on'] as bool;
    final p = await mustPage(id);
    final noop = p.isFavorite == on;
    if (!noop) await gw.setFavorite(id, on);
    return UndoRecord(
      type: type,
      data: {'page_id': id, 'after': on, 'noop': noop},
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    if (r.data['noop'] == true) return UndoOutcome.reverted;
    final id = r.data['page_id'] as String;
    final p = await gw.page(id);
    if (p == null) return UndoOutcome.skippedGone;
    final after = r.data['after'] as bool;
    if (p.isFavorite != after) return UndoOutcome.skippedChanged;
    await gw.setFavorite(id, !after);
    return UndoOutcome.reverted;
  }
}

class _Delete extends _Base {
  _Delete(super.gw);

  @override
  String get type => 'page.delete';

  @override
  String text(AssistAction a, String label) => 'Move $label to Trash';

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: text(a, _label(labels, a.fields['page_id'])),
        destructive: true,
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    final id = a.fields['page_id'] as String;
    await mustPage(id);
    await gw.delete(id);
    return UndoRecord(type: type, data: {'page_id': id});
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['page_id'] as String;
    if (await gw.page(id) != null) return UndoOutcome.reverted;
    try {
      await gw.restore(id);
    } catch (_) {
      return UndoOutcome.skippedGone;
    }
    return UndoOutcome.reverted;
  }
}
