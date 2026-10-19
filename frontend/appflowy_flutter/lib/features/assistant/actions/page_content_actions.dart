import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/gateways/page_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';

List<ActionHandler> pageContentHandlers(PageGateway gw) =>
    [_Create(gw), _Append(gw)];

/// Null = a valid page name, else why not.
String? pageNameError(Object? t) {
  if (t is! String || t.trim().isEmpty) return 'Name is empty';
  if (t.trim().length > 120 || t.contains(RegExp(r'[\r\n]'))) {
    return 'Name is too long';
  }
  return null;
}

String? _content(Object? c) {
  if (c is! String || c.trim().isEmpty) return 'Content is empty';
  if (c.length > 20000) return 'Content is too long';
  return null;
}

/// Above the 20000-char content cap, so undo compares whole pages.
const _wholePage = 1 << 20;

/// Temps made by these can hold pages.
const pageContainerActions = {'page.create', 'board.create', 'database.create'};

/// A page/space from context, or a page, board or database an earlier action
/// creates; never a card, column or entry.
bool isPageParent(ValidationScope scope, Object? id) =>
    scope.knownIds.contains(id) && scope.items[id]?['layout'] != null ||
    scope.boundTemps.contains(id) &&
        pageContainerActions.contains(scope.items[id]?['created_by']);

String? _after(Object? c) {
  final s = c is String ? c : '';
  return s.length > 200 ? s.substring(0, 200) : s;
}

abstract class _Base implements ActionHandler {
  _Base(this.gw);
  final PageGateway gw;

  @override
  AssistStage get stage => AssistStage.pages;

  /// The page, or throws if it is gone or locked. Call before any write.
  Future<PageRef> mustPage(String id) async {
    final p = await gw.page(id);
    if (p == null || !p.editable) throw StateError("Page can't be edited");
    return p;
  }
}

class _Create extends _Base {
  _Create(super.gw);

  @override
  String get type => 'page.create';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final id = a.fields['parent_id'];
    if (!isPageParent(scope, id)) return 'Unknown parent_id';
    if (scope.readOnlyIds.contains(id)) return 'Page is locked';
    return pageNameError(a.fields['name']) ?? _content(a.fields['content']);
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) {
    final parent = labels[a.fields['parent_id']] ?? '';
    return ActionPreview(
      text: 'New page: ${a.fields['name']}'
          '${parent.isEmpty ? '' : ' in $parent'}',
      after: _after(a.fields['content']),
      editable: const ['name', 'content'],
    );
  }

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    mustBeValid(
      pageNameError(a.fields['name']) ?? _content(a.fields['content']),
    );
    final parent = scope.resolve(a.fields['parent_id'] as String);
    await mustPage(parent);
    final id = await gw.createPage(
      parent,
      (a.fields['name'] as String).trim(),
      a.fields['content'] as String,
    );
    // What the page holds now, so undo can tell if the user changed it.
    final String? md;
    try {
      md = await gw.markdown(id, cap: _wholePage);
    } catch (_) {
      try {
        await gw.delete(id);
      } catch (_) {}
      rethrow;
    }
    final temp = a.tempId;
    if (temp != null) scope.bind(temp, id);
    return UndoRecord(type: type, data: {'page_id': id, 'markdown': md});
  }

  /// A page the user has written in or put pages under since is kept.
  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    final id = r.data['page_id'] as String;
    if (await gw.page(id) == null) return UndoOutcome.skippedGone;
    if ((await gw.childIds(id)).isNotEmpty ||
        await gw.markdown(id, cap: _wholePage) != r.data['markdown']) {
      return UndoOutcome.skippedChanged;
    }
    await gw.delete(id);
    return UndoOutcome.reverted;
  }
}

class _Append extends _Base {
  _Append(super.gw);

  @override
  String get type => 'page.append';

  @override
  String? validate(AssistAction a, ValidationScope scope) {
    final id = a.fields['page_id'];
    if (!scope.knownIds.contains(id) ||
        scope.items[id]?['layout'] != 'document') {
      return 'Not a document page';
    }
    if (scope.readOnlyIds.contains(id)) return 'Page is locked';
    return _content(a.fields['content']);
  }

  @override
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      ActionPreview(
        text: 'Add to ${labels[a.fields['page_id']] ?? ''}',
        after: _after(a.fields['content']),
        editable: const ['content'],
      );

  @override
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope) async {
    mustBeValid(_content(a.fields['content']));
    final id = scope.resolve(a.fields['page_id'] as String);
    if ((await mustPage(id)).layout != 'document') {
      throw StateError('Not a document page');
    }
    final md = a.fields['content'] as String;
    final blocks = await gw.append(id, md);
    return UndoRecord(
      type: type,
      data: {
        'page_id': id,
        'block_ids': blocks.contentIds,
        'pad_ids': blocks.padIds,
        'markdown': md,
      },
    );
  }

  @override
  Future<UndoOutcome> undo(UndoRecord r) async {
    // Idempotent: a repeat finds the blocks already gone.
    if (r.data['removed'] == true) return UndoOutcome.skippedGone;
    final id = r.data['page_id'] as String;
    final p = await gw.page(id);
    if (p == null) return UndoOutcome.skippedGone;
    if (!p.editable) return UndoOutcome.skippedChanged;
    final removed = await gw.removeBlocksIfUnchanged(
      id,
      blockIds: (r.data['block_ids'] as List).cast<String>(),
      padIds: (r.data['pad_ids'] as List? ?? const []).cast<String>(),
      expectedMarkdown: r.data['markdown'] as String,
    );
    if (!removed) return UndoOutcome.skippedChanged;
    r.data['removed'] = true;
    return UndoOutcome.reverted;
  }
}

/// The page tree; markdown for up to 3 mentioned document pages.
Future<ContextPart> pageContext(
  PageGateway gw,
  List<String> mentionedPageIds,
) async {
  final tree = await gw.tree();
  final docs = {
    for (final p in tree)
      if (p.layout == 'document') p.id,
  };
  final texts = <Map<String, dynamic>>[];
  for (final id in mentionedPageIds.where(docs.contains).toSet().take(3)) {
    final md = await gw.markdown(id);
    if (md != null) texts.add({'id': id, 'markdown': md});
  }
  return ContextPart(
    json: {
      'pages': [
        for (final p in tree)
          {
            'id': p.id,
            'name': p.name,
            'parent_id': p.parentId,
            'layout': p.layout,
          },
      ],
      'page_texts': texts,
    },
    labels: {
      for (final p in tree) p.id: p.name.isEmpty ? 'Untitled' : p.name,
      // The current parent's label, for page.move's preview.
      for (final p in tree)
        '${p.id}#parent': tree
                .where((q) => q.id == p.parentId)
                .map((q) => q.name.isEmpty ? 'Untitled' : q.name)
                .firstOrNull ??
            '',
    },
    ids: {for (final p in tree) p.id},
    readOnlyIds: {
      for (final p in tree)
        if (!p.editable) p.id,
    },
    items: {
      for (final p in tree) p.id: {'layout': p.layout, 'parent_id': p.parentId},
    },
  );
}
