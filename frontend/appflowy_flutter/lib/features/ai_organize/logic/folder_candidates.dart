import 'package:appflowy/workspace/application/view/view_ext.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';

class FolderCandidate {
  const FolderCandidate({required this.id, required this.path});

  final String id;
  final String path;

  Map<String, String> toJson() => {'id': id, 'path': path};
}

/// Ancestor chain of [viewId], root (space) first, ending with the view itself.
/// Null if the chain breaks (missing parent, cycle) before reaching a space.
List<ViewPB>? _chain(String viewId, Map<String, ViewPB> byId) {
  final chain = <ViewPB>[];
  final seen = <String>{};
  var current = byId[viewId];
  while (current != null && seen.add(current.id)) {
    chain.add(current);
    if (current.isSpace) {
      return chain.reversed.toList();
    }
    current = byId[current.parentViewId];
  }
  return null;
}

String _label(ViewPB v) => v.name.isEmpty ? 'Untitled' : v.name;

/// 'Space / Page / Sub' (empty names -> 'Untitled'), or null if the parent
/// chain breaks before reaching a space.
String? viewPath(String viewId, Map<String, ViewPB> byId) =>
    _chain(viewId, byId)?.map(_label).join(' / ');

/// [views] is the flat list from ViewBackendService.getAllViews()
/// (trash already filtered out).
List<FolderCandidate> buildFolderCandidates({
  required List<ViewPB> views,
  required String noteId,
}) {
  final byId = {for (final v in views) v.id: v};
  final parents = {for (final v in views) v.parentViewId};
  // Unknown note space: no safe visibility to match, offer nothing.
  final noteSpace = _chain(noteId, byId)?.first;
  if (noteSpace == null) {
    return [];
  }

  final result = <FolderCandidate>[];
  for (final v in views) {
    if (!v.isSpace && (v.layout != ViewLayoutPB.Document || v.isLocked)) {
      continue;
    }
    if (!v.isSpace && !parents.contains(v.id)) {
      continue;
    }
    final chain = _chain(v.id, byId);
    if (chain == null ||
        chain.first.spacePermission != noteSpace.spacePermission ||
        chain.any((a) => a.id == noteId)) {
      continue;
    }
    result.add(
      FolderCandidate(id: v.id, path: chain.map(_label).join(' / ')),
    );
  }
  result.sort((a, b) => a.path.compareTo(b.path));
  return result;
}
