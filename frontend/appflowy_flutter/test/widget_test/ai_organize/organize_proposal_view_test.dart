import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_proposal_view.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widget_test_wrapper.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableLevels = [];
    await EasyLocalization.ensureInitialized();
  });

  final proposal = OrganizeProposal(
    id: 'p1',
    noteId: 'n1',
    createdAt: DateTime(2026),
    snapshot: const NoteSnapshot(
      title: 'Untitled',
      parentId: 'root',
      bodyHash: 'h',
    ),
    proposedTitle: 'Groceries',
    proposedFolderId: 'f1',
    proposedFolderPath: 'Home',
    currentFolderPath: 'Inbox',
    reason: 'Looks like a shopping list',
    state: ProposalState.needsReview,
  );

  Future<(List<OrganizeDecision>, List<int>)> pump(WidgetTester tester) async {
    final applied = <OrganizeDecision>[];
    final rejected = <int>[];
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: OrganizeProposalView(
          proposal: proposal,
          candidates: const [],
          onApply: applied.add,
          onReject: () => rejected.add(1),
        ),
      ),
    );
    return (applied, rejected);
  }

  testWidgets('apply sends both fields by default', (tester) async {
    final (applied, _) = await pump(tester);
    await tester.tap(find.text('aiOrganize.applySelected'));
    expect(applied.single.title, 'Groceries');
    expect(applied.single.folderId, 'f1');
  });

  testWidgets('unchecked field is not sent', (tester) async {
    final (applied, _) = await pump(tester);
    await tester.tap(find.text('aiOrganize.folderRow'));
    await tester.pump();
    await tester.tap(find.text('aiOrganize.applySelected'));
    expect(applied.single.folderId, isNull);
    expect(applied.single.title, 'Groceries');
  });

  testWidgets('edited title is sent', (tester) async {
    final (applied, _) = await pump(tester);
    await tester.enterText(find.byType(TextField), 'Weekly groceries');
    await tester.tap(find.text('aiOrganize.applySelected'));
    expect(applied.single.title, 'Weekly groceries');
  });

  testWidgets('reject calls onReject', (tester) async {
    final (applied, rejected) = await pump(tester);
    await tester.tap(find.text('aiOrganize.reject'));
    expect(rejected, hasLength(1));
    expect(applied, isEmpty);
  });

  testWidgets('apply is disabled when nothing would be sent', (tester) async {
    final (applied, _) = await pump(tester);
    await tester.tap(find.text('aiOrganize.folderRow'));
    await tester.pump();
    await tester.tap(find.text('aiOrganize.titleRow'));
    await tester.pump();
    await tester.tap(find.text('aiOrganize.applySelected'));
    expect(applied, isEmpty);
    // a blank title alone also disables Apply
    await tester.tap(find.text('aiOrganize.titleRow'));
    await tester.enterText(find.byType(TextField), '  ');
    await tester.pump();
    await tester.tap(find.text('aiOrganize.applySelected'));
    expect(applied, isEmpty);
  });
}
