import 'package:appflowy/plugins/document/application/document_bloc.dart';
import 'package:appflowy/plugins/document/application/document_data_pb_extension.dart';
import 'package:appflowy/plugins/document/application/document_service.dart';
import 'package:appflowy/plugins/trash/application/trash_service.dart';
import 'package:appflowy/shared/markdown_to_document.dart';
import 'package:appflowy/workspace/application/view/view_ext.dart';
import 'package:appflowy/workspace/application/view/view_service.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/protobuf.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/foundation.dart';

class PageRef {
  const PageRef({
    required this.id,
    required this.name,
    required this.parentId,
    required this.layout,
    required this.editable,
  });

  /// [layout]: space | document | grid | board | calendar | chat.
  final String id, name, parentId, layout;

  /// False when locked.
  final bool editable;
}

/// Thin wrapper over the folder/document services; not unit-tested. Every
/// failed backend call throws.
class PageGateway {
  Future<List<PageRef>> tree({int cap = 500}) async {
    final views = (await ViewBackendService.getAllViews()).getOrThrow().items;
    return [for (final v in views.take(cap)) _ref(v)];
  }

  /// Null when missing or in Trash.
  Future<PageRef?> page(String id) async {
    final v = (await ViewBackendService.getView(id)).toNullable();
    return v == null ? null : _ref(v);
  }

  PageRef _ref(ViewPB v) => PageRef(
        id: v.id,
        name: v.name,
        parentId: v.parentViewId,
        layout: v.isSpace
            ? 'space'
            : switch (v.layout) {
                ViewLayoutPB.Document => 'document',
                ViewLayoutPB.Grid => 'grid',
                ViewLayoutPB.Board => 'board',
                ViewLayoutPB.Calendar => 'calendar',
                ViewLayoutPB.Chat => 'chat',
                _ => 'other',
              },
        editable: !v.isLocked,
      );

  /// The page's text as markdown, cut to [cap] chars; null if unreadable.
  Future<String?> markdown(String pageId, {int cap = 8000}) async {
    final data =
        (await DocumentService().getDocument(documentId: pageId)).toNullable();
    final doc = data?.toDocument();
    if (doc == null) return null;
    final md = await customDocumentToMarkdown(doc);
    return md.length > cap ? md.substring(0, cap) : md;
  }

  /// A document page under [parentId] holding [markdown]; returns its id.
  Future<String> createPage(
    String parentId,
    String name,
    String markdown,
  ) async {
    final bytes =
        DocumentDataPBFromTo.fromDocument(customMarkdownToDocument(markdown))
                ?.writeToBuffer() ??
            (throw StateError("Couldn't convert the content"));
    final view = (await ViewBackendService.createView(
      layoutType: ViewLayoutPB.Document,
      parentViewId: parentId,
      name: name,
      initialDataBytes: bytes,
    ))
        .getOrThrow();
    return view.id;
  }

  /// Adds [markdown] at the end of the page; see [appendMarkdown].
  Future<AppendedBlocks> append(String pageId, String markdown) =>
      _withEditor(pageId, (editor) => appendMarkdown(editor, markdown));

  /// See [removeIfUnchanged].
  Future<bool> removeBlocksIfUnchanged(
    String pageId, {
    required List<String> blockIds,
    required List<String> padIds,
    required String expectedMarkdown,
  }) =>
      _withEditor(
        pageId,
        (editor) => removeIfUnchanged(
          editor,
          contentIds: blockIds,
          padIds: padIds,
          expectedMarkdown: expectedMarkdown,
        ),
      );

  /// Runs [run] on the page's open editor when there is one (its bloc saves
  /// the change and the user sees it), else on a temporary one that is closed
  /// afterwards. Never closes an editor it didn't open.
  Future<T> _withEditor<T>(
    String pageId,
    Future<T> Function(EditorState editor) run,
  ) async {
    final open = DocumentBloc.findOpen(pageId);
    if (open != null) return run(await _editor(open, pageId));
    final bloc = DocumentBloc(documentId: pageId, saveToBlocMap: false)
      ..add(const DocumentEvent.initial());
    try {
      return await run(await _editor(bloc, pageId));
    } finally {
      await bloc.close();
    }
  }

  /// Throws if the page fails to load or takes over 10 s, so an apply can't
  /// hang while holding the proposal's busy guard.
  Future<EditorState> _editor(DocumentBloc bloc, String pageId) async {
    bool ready(DocumentState s) => s.editorState != null || s.error != null;
    final s = ready(bloc.state)
        ? bloc.state
        : await bloc.stream
            .firstWhere(ready)
            .timeout(const Duration(seconds: 10));
    return s.editorState ??
        (throw StateError("Couldn't open page $pageId: ${s.error}"));
  }

  /// To Trash.
  Future<void> delete(String pageId) async =>
      (await ViewBackendService.deleteView(viewId: pageId)).getOrThrow();

  /// From Trash (trash id == view id).
  Future<void> restore(String pageId) async =>
      (await TrashService.putback(pageId)).getOrThrow();
}

typedef AppendedBlocks = ({List<String> contentIds, List<String> padIds});

/// Adds [markdown] at the end of [editor]'s document in one transaction, as
/// ChatEditDocumentService.addMessagesToPage does: a blank paragraph before
/// it (unless the last block is already empty) and one after. Returns the
/// content block ids and the padding paragraph ids.
Future<AppendedBlocks> appendMarkdown(
  EditorState editor,
  String markdown,
) async {
  if (!editor.editable) throw StateError('Page is locked');
  final content = [
    for (final n in customMarkdownToDocument(markdown).root.children)
      n.deepCopy(),
  ];
  if (content.isEmpty) throw StateError("Couldn't convert the content");
  final last = editor.document.root.children.lastOrNull;
  final lastEmpty =
      last != null && last.children.isEmpty && last.delta?.isEmpty == true;
  final path = last == null || listEquals(last.path, const [0]) && lastEmpty
      ? const [0]
      : last.path.next;
  final lead = lastEmpty ? null : paragraphNode();
  final trail = paragraphNode();
  // deepCopy: false keeps these nodes, so their ids are the stored block ids.
  final t = editor.transaction
    ..insertNodes(
      path,
      [if (lead != null) lead, ...content, trail],
      deepCopy: false,
    );
  await editor.apply(t);
  return (
    contentIds: [for (final n in content) n.id],
    padIds: [if (lead != null) lead.id, trail.id],
  );
}

/// Deletes the appended blocks in one transaction when every content block
/// is still there and still reads as [expectedMarkdown] (compared after the
/// same markdown round trip); padding paragraphs go too while still blank.
/// Otherwise changes nothing and returns false.
Future<bool> removeIfUnchanged(
  EditorState editor, {
  required List<String> contentIds,
  required List<String> padIds,
  required String expectedMarkdown,
}) async {
  if (!editor.editable) return false;
  final byId = <String, Node>{};
  void walk(Node n) {
    byId[n.id] = n;
    n.children.forEach(walk);
  }

  walk(editor.document.root);
  final content = [for (final id in contentIds) byId[id]];
  if (content.isEmpty || content.contains(null)) return false;
  final found = content.nonNulls.toList();
  final expected = customMarkdownToDocument(expectedMarkdown).root.children;
  if (await _md(found) != await _md(expected)) return false;
  final pads = [
    for (final id in padIds)
      if (byId[id] case final n? when _blank(n)) n,
  ];
  await editor.apply(editor.transaction..deleteNodes([...found, ...pads]));
  return true;
}

bool _blank(Node n) =>
    n.type == ParagraphBlockKeys.type &&
    n.children.isEmpty &&
    (n.delta?.isEmpty ?? true);

Future<String> _md(Iterable<Node> nodes) => customDocumentToMarkdown(
      Document(root: pageNode(children: [for (final n in nodes) n.deepCopy()])),
    );
