import 'dart:convert';

import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:crypto/crypto.dart';

const kMaxNoteChars = 8000;
const kMaxFolders = 300;

String bodyHash(String text) => sha256.convert(utf8.encode(text)).toString();

/// prevSiblingId is ignored: siblings moving around is not a content change.
bool isStale(NoteSnapshot taken, NoteSnapshot now) =>
    taken.title != now.title ||
    taken.parentId != now.parentId ||
    taken.bodyHash != now.bodyHash;

/// Undo only if the note still has the value we set; a folder undo also needs
/// the original parent to still exist.
bool canUndo(
  HistoryEntry entry,
  NoteSnapshot now, {
  required bool beforeParentExists,
}) =>
    switch (entry.field) {
      OrganizeField.title => now.title == entry.after,
      OrganizeField.folder => now.parentId == entry.after && beforeParentExists,
    };

ProposalState finalState(OrganizeProposal p, Set<OrganizeField> applied) {
  final proposed = {
    if (p.proposedTitle != null) OrganizeField.title,
    if (p.proposedFolderId != null) OrganizeField.folder,
  };
  if (applied.isEmpty) return ProposalState.rejected;
  return applied.containsAll(proposed)
      ? ProposalState.applied
      : ProposalState.partiallyApplied;
}
