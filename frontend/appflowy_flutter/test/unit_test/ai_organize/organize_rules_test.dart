import 'dart:convert';

import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/organize_rules.dart';
import 'package:flutter_test/flutter_test.dart';

NoteSnapshot snap({
  String title = 't',
  String parentId = 'p',
  String? prev,
  String hash = 'h',
}) =>
    NoteSnapshot(
      title: title,
      parentId: parentId,
      prevSiblingId: prev,
      bodyHash: hash,
    );

HistoryEntry entry(OrganizeField field, String before, String after) =>
    HistoryEntry(
      proposalId: 'p1',
      noteId: 'n1',
      field: field,
      appliedAt: DateTime.utc(2026, 1, 2),
      before: before,
      after: after,
      beforeLabel: before,
      afterLabel: after,
    );

OrganizeProposal proposal({String? folderId}) => OrganizeProposal(
      id: 'p1',
      noteId: 'n1',
      createdAt: DateTime.utc(2026),
      snapshot: snap(prev: 's'),
      proposedTitle: 'New',
      proposedFolderId: folderId,
      proposedFolderPath: folderId == null ? null : 'A/B',
      currentFolderPath: 'A',
      reason: 'because',
      state: ProposalState.needsReview,
    );

void main() {
  test('bodyHash is stable and content-sensitive', () {
    expect(bodyHash('a'), bodyHash('a'));
    expect(bodyHash('a'), isNot(bodyHash('b')));
    expect(bodyHash('a').length, 64);
  });

  test('isStale detects title, parent and body changes only', () {
    final base = snap();
    expect(isStale(base, snap(title: 'x')), isTrue);
    expect(isStale(base, snap(parentId: 'x')), isTrue);
    expect(isStale(base, snap(hash: 'x')), isTrue);
    expect(isStale(base, snap(prev: 'x')), isFalse);
  });

  test('canUndo title only when current title equals after', () {
    final e = entry(OrganizeField.title, 'Old', 'New');
    expect(canUndo(e, snap(title: 'New'), beforeParentExists: true), isTrue);
    expect(canUndo(e, snap(title: 'Other'), beforeParentExists: true), isFalse);
  });

  test('canUndo folder needs same parent and existing original', () {
    final e = entry(OrganizeField.folder, 'old', 'new');
    expect(canUndo(e, snap(parentId: 'new'), beforeParentExists: true), isTrue);
    expect(
      canUndo(e, snap(parentId: 'new'), beforeParentExists: false),
      isFalse,
    );
    expect(canUndo(e, snap(parentId: 'x'), beforeParentExists: true), isFalse);
  });

  test('finalState', () {
    final both = proposal(folderId: 'f');
    expect(
      finalState(both, {OrganizeField.title, OrganizeField.folder}),
      ProposalState.applied,
    );
    expect(
      finalState(both, {OrganizeField.title}),
      ProposalState.partiallyApplied,
    );
    expect(finalState(both, {}), ProposalState.rejected);
    expect(
      finalState(proposal(), {OrganizeField.title}),
      ProposalState.applied,
    );
  });

  test('OrganizeState JSON round trip', () {
    final p = proposal(folderId: 'f')..error = OrganizeErrorKind.userLimit;
    final s = OrganizeState(
      consented: true,
      proposals: [p],
      history: [
        HistoryEntry(
          proposalId: 'p1',
          noteId: 'n1',
          field: OrganizeField.folder,
          appliedAt: DateTime.utc(2026, 1, 2),
          before: 'a',
          after: 'b',
          beforePrevSiblingId: 'c',
          beforeLabel: 'A',
          afterLabel: 'B',
          undone: true,
        ),
      ],
      rejections: {
        'n1': Rejections(bodyHash: 'h', titles: ['x'], folderIds: ['y']),
      },
    );
    final encoded = jsonEncode(s.toJson());
    final again = OrganizeState.fromJson(jsonDecode(encoded));
    expect(jsonEncode(again.toJson()), encoded);
    expect(again.proposals.single.error, OrganizeErrorKind.userLimit);
    expect(again.history.single.key, 'p1:folder');
  });
}
