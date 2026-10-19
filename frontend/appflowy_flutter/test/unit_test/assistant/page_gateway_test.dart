import 'package:appflowy/features/assistant/gateways/page_gateway.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

EditorState editor(List<Node> blocks) =>
    EditorState(document: Document(root: pageNode(children: blocks)));

List<String> texts(EditorState e) => [
      for (final n in e.document.root.children)
        '${n.type}:${n.delta?.toPlainText() ?? ''}',
    ];

Node byId(EditorState e, String id) =>
    e.document.root.children.firstWhere((n) => n.id == id);

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('append adds content + blank padding at the end; ids exist', () async {
    final e = editor([paragraphNode(text: 'Intro')]);
    final r = await appendMarkdown(e, '- [ ] Socks\n- [ ] Hat');
    expect(texts(e), [
      'paragraph:Intro',
      'paragraph:',
      'todo_list:Socks',
      'todo_list:Hat',
      'paragraph:',
    ]);
    final content = [for (final id in r.contentIds) byId(e, id)];
    expect([for (final n in content) n.delta!.toPlainText()], ['Socks', 'Hat']);
    final all = e.document.root.children.toList();
    expect([for (final id in r.padIds) all.indexOf(byId(e, id))], [1, 4]);
  });

  test('unchanged: content and padding go, the trailing blank survives',
      () async {
    final e = editor([paragraphNode(text: 'Intro'), paragraphNode()]);
    final before = texts(e);
    final r = await appendMarkdown(e, 'Note');
    expect(r.padIds, hasLength(1), reason: 'last block was already blank');
    expect(
      await removeIfUnchanged(
        e,
        contentIds: r.contentIds,
        padIds: r.padIds,
        expectedMarkdown: 'Note',
      ),
      isTrue,
    );
    expect(texts(e), before);
  });

  test('one edited line keeps everything', () async {
    final e = editor([paragraphNode(text: 'Intro')]);
    final r = await appendMarkdown(e, '- a\n- b');
    await e.apply(e.transaction..insertText(byId(e, r.contentIds[1]), 1, '!'));
    final after = texts(e);
    expect(
      await removeIfUnchanged(
        e,
        contentIds: r.contentIds,
        padIds: r.padIds,
        expectedMarkdown: '- a\n- b',
      ),
      isFalse,
    );
    expect(texts(e), after);
  });

  test('a removed content block keeps everything', () async {
    final e = editor([paragraphNode(text: 'Intro')]);
    final r = await appendMarkdown(e, '- a\n- b');
    await e.apply(e.transaction..deleteNode(byId(e, r.contentIds[0])));
    expect(
      await removeIfUnchanged(
        e,
        contentIds: r.contentIds,
        padIds: r.padIds,
        expectedMarkdown: '- a\n- b',
      ),
      isFalse,
    );
  });

  test('text typed into padding keeps that paragraph, content still goes',
      () async {
    final e = editor([paragraphNode(text: 'Intro')]);
    final r = await appendMarkdown(e, 'Note');
    await e.apply(e.transaction..insertText(byId(e, r.padIds.last), 0, 'Mine'));
    expect(
      await removeIfUnchanged(
        e,
        contentIds: r.contentIds,
        padIds: r.padIds,
        expectedMarkdown: 'Note',
      ),
      isTrue,
    );
    expect(texts(e), ['paragraph:Intro', 'paragraph:Mine']);
  });

  test('"* a" and "- a" compare equal', () async {
    final e = editor([paragraphNode(text: 'Intro')]);
    final r = await appendMarkdown(e, '* a\n* b');
    expect(
      await removeIfUnchanged(
        e,
        contentIds: r.contentIds,
        padIds: r.padIds,
        expectedMarkdown: '- a\n- b',
      ),
      isTrue,
    );
    expect(texts(e), ['paragraph:Intro']);
  });

  test('append into an empty document', () async {
    final e = editor([]);
    final r = await appendMarkdown(e, '# Title');
    expect(texts(e), ['paragraph:', 'heading:Title', 'paragraph:']);
    expect(r.contentIds, hasLength(1));
  });
}
