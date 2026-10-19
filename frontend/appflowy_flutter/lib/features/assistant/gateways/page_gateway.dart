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

  /// Adds [markdown] at the end of the page in one transaction, as
  /// ChatEditDocumentService.addMessagesToPage does (with a blank line before
  /// and after). Returns the inserted top-level block ids, blanks included.
  Future<List<String>> append(String pageId, String markdown) =>
      _withEditor(pageId, (editor) async {
        final content = customMarkdownToDocument(markdown).root.children;
        if (content.isEmpty) throw StateError("Couldn't convert the content");
        final last = editor.document.root.children.lastOrNull;
        final lastEmpty = last?.children.isNotEmpty == false &&
            last?.delta?.isNotEmpty == false;
        final path =
            last == null || listEquals(last.path, const [0]) && lastEmpty
                ? const [0]
                : last.path.next;
        final t = editor.transaction
          ..insertNodes(path, [
            if (last == null || !lastEmpty) paragraphNode(),
            ...content,
            paragraphNode(),
          ]);
        // insertNodes copies the nodes under new ids; these are what's stored.
        final ids = [
          for (final op in t.operations.whereType<InsertOperation>())
            for (final n in op.nodes) n.id,
        ];
        await editor.apply(t);
        return ids;
      });

  /// Deletes [blockIds] in one transaction if all are still there and their
  /// text still reads as [expectedMarkdown] (blank paragraphs ignored);
  /// otherwise leaves the page alone and returns false.
  Future<bool> removeBlocksIfUnchanged(
    String pageId,
    List<String> blockIds,
    String expectedMarkdown,
  ) =>
      _withEditor(pageId, (editor) async {
        final byId = <String, Node>{};
        void walk(Node n) {
          byId[n.id] = n;
          n.children.forEach(walk);
        }

        walk(editor.document.root);
        final nodes = [for (final id in blockIds) byId[id]];
        if (nodes.contains(null)) return false;
        final found = nodes.nonNulls.toList();
        final expected =
            customMarkdownToDocument(expectedMarkdown).root.children;
        if (await _md(found) != await _md(expected)) return false;
        await editor.apply(editor.transaction..deleteNodes(found));
        return true;
      });

  Future<String> _md(Iterable<Node> nodes) => customDocumentToMarkdown(
        Document(
          root: pageNode(
            children: [
              for (final n in nodes)
                if (n.type != ParagraphBlockKeys.type ||
                    n.children.isNotEmpty ||
                    n.delta?.isNotEmpty == true)
                  n.deepCopy(),
            ],
          ),
        ),
      );

  Future<T> _withEditor<T>(
    String pageId,
    Future<T> Function(EditorState editor) run,
  ) async {
    final bloc = DocumentBloc(documentId: pageId, saveToBlocMap: false)
      ..add(const DocumentEvent.initial());
    try {
      final s = bloc.state.editorState != null || bloc.state.error != null
          ? bloc.state
          : await bloc.stream
              .firstWhere((s) => s.editorState != null || s.error != null);
      final editor = s.editorState ??
          (throw StateError("Couldn't open page $pageId: ${s.error}"));
      return await run(editor);
    } finally {
      await bloc.close();
    }
  }

  /// To Trash.
  Future<void> delete(String pageId) async =>
      (await ViewBackendService.deleteView(viewId: pageId)).getOrThrow();

  /// From Trash (trash id == view id).
  Future<void> restore(String pageId) async =>
      (await TrashService.putback(pageId)).getOrThrow();
}
