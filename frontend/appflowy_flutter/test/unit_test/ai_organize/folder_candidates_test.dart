import 'dart:convert';

import 'package:appflowy/features/ai_organize/logic/folder_candidates.dart';
import 'package:appflowy/workspace/application/view/view_ext.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';
import 'package:flutter_test/flutter_test.dart';

ViewPB v(
  String id,
  String parent, {
  String name = '',
  ViewLayoutPB layout = ViewLayoutPB.Document,
  bool locked = false,
  int? space,
}) {
  final view = ViewPB()
    ..id = id
    ..parentViewId = parent
    ..name = name
    ..layout = layout
    ..isLocked = locked;
  if (space != null) {
    view.extra = jsonEncode({
      ViewExtKeys.isSpaceKey: true,
      ViewExtKeys.spacePermissionKey: space,
    });
  }
  return view;
}

void main() {
  final views = [
    v('S1', 'ws', name: 'S1', space: 0),
    v('A', 'S1', name: 'A'),
    v('N', 'A', name: 'N'),
    v('N1', 'N', name: 'N1'),
    v('N2', 'N1', name: 'N2'),
    v('A2', 'A', name: 'A2'),
    v('B', 'S1', name: 'B'),
    v('G', 'S1', name: 'G', layout: ViewLayoutPB.Grid),
    v('G1', 'G', name: 'G1'),
    v('L', 'S1', name: 'L', locked: true),
    v('L1', 'L', name: 'L1'),
    v('U', 'S1'),
    v('U1', 'U', name: 'U1'),
    v('S2', 'ws', name: 'S2', space: 1),
    v('P', 'S2', name: 'P'),
    v('P1', 'P', name: 'P1'),
    v('O', 'gone', name: 'O'),
    v('O1', 'O', name: 'O1'),
  ];

  List<String> ids(String noteId) =>
      buildFolderCandidates(views: views, noteId: noteId)
          .map((c) => c.id)
          .toList();

  test('includes spaces and document pages with children', () {
    final result = buildFolderCandidates(views: views, noteId: 'N');
    expect(result.map((c) => c.id), ['S1', 'A', 'U']);
    expect(result.map((c) => c.path), ['S1', 'S1 / A', 'S1 / Untitled']);
    expect(result.first.toJson(), {'id': 'S1', 'path': 'S1'});
  });

  test('excludes note, its descendants, grids, locked, childless', () {
    expect(
      ids('N').toSet().intersection({'N', 'N1', 'N2', 'B', 'G', 'L'}),
      isEmpty,
    );
  });

  test('excludes other visibility', () {
    expect(ids('N').toSet().intersection({'S2', 'P'}), isEmpty);
    expect(ids('P1'), ['S2', 'P']);
  });

  test('excludes broken chains', () {
    expect(ids('N'), isNot(contains('O')));
  });

  test('viewPath and cycles', () {
    final byId = {for (final x in views) x.id: x};
    expect(viewPath('N', byId), 'S1 / A / N');
    expect(viewPath('O1', byId), isNull);
    final cyc = {'X': v('X', 'Y'), 'Y': v('Y', 'X')};
    expect(viewPath('X', cyc), isNull);
  });
}
