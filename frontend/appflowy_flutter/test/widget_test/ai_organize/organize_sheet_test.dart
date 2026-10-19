import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/folder_candidates.dart';
import 'package:appflowy/features/ai_organize/logic/organize_service.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_sheet.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widget_test_wrapper.dart';

class _MockService extends Mock implements OrganizeService {}

OrganizeProposal _proposal({
  ProposalState state = ProposalState.needsReview,
  OrganizeErrorKind? error,
}) =>
    OrganizeProposal(
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
      reason: 'r',
      state: state,
      error: error,
    );

void main() {
  setUpAll(() async {
    registerFallbackValue(const OrganizeDecision());
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableLevels = [];
    await EasyLocalization.ensureInitialized();
  });

  late _MockService service;

  setUp(() {
    service = _MockService();
    when(() => service.state()).thenAnswer((_) async => OrganizeState());
    when(() => service.setConsented()).thenAnswer((_) async {});
    when(() => service.request(any())).thenAnswer((_) async => null);
  });

  Future<void> open(WidgetTester tester, {String? proposalId}) async {
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOrganizeSheetFor(
              context,
              service,
              noteId: 'n1',
              proposalId: proposalId,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('declining consent sends nothing', (tester) async {
    await open(tester);
    expect(find.text('aiOrganize.consentTitle'), findsOneWidget);
    await tester.tap(find.text('button.cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => service.setConsented());
    verifyNever(() => service.request(any()));
  });

  testWidgets('accepting consent records it, then requests', (tester) async {
    await open(tester);
    await tester.tap(find.text('aiOrganize.consentAccept'));
    await tester.pumpAndSettle();
    verifyInOrder([
      () => service.setConsented(),
      () => service.request('n1'),
    ]);
    expect(find.text('aiOrganize.nothingToSuggest'), findsOneWidget);
  });

  testWidgets('Apply anyway keeps the choices the user made', (tester) async {
    final p = _proposal();
    when(() => service.state())
        .thenAnswer((_) async => OrganizeState(consented: true));
    when(() => service.request('n1')).thenAnswer((_) async => p);
    when(() => service.candidatesFor('n1')).thenAnswer(
      (_) async => const [FolderCandidate(id: 'f1', path: 'Home')],
    );
    // Always stale: keeps the sheet open (a toast needs a theme the test
    // harness lacks) and the decision is all this test checks.
    when(() => service.apply(any(), any(), force: any(named: 'force')))
        .thenAnswer((_) async {
      p.state = ProposalState.stale;
      return p.state;
    });

    await open(tester);
    await tester.tap(find.text('aiOrganize.folderRow'));
    await tester.pump();
    await tester.tap(find.text('aiOrganize.applySelected'));
    await tester.pumpAndSettle();
    expect(find.text('aiOrganize.stale'), findsOneWidget);
    await tester.tap(find.text('aiOrganize.applyAnyway'));
    await tester.pumpAndSettle();

    final d = verify(() => service.apply('p1', captureAny(), force: true))
        .captured
        .single as OrganizeDecision;
    expect(d.folderId, isNull);
    expect(d.title, 'Groceries');
  });

  testWidgets('switched off: failed proposal offers Dismiss, not Retry',
      (tester) async {
    final p = _proposal(
      state: ProposalState.failed,
      error: OrganizeErrorKind.failed,
    );
    when(() => service.state()).thenAnswer(
      (_) async =>
          OrganizeState(enabled: false, consented: true, proposals: [p]),
    );
    when(() => service.reject('p1')).thenAnswer((_) async {});

    await open(tester, proposalId: 'p1');
    expect(find.text('aiOrganize.retry'), findsNothing);
    await tester.tap(find.text('aiOrganize.reject'));
    await tester.pumpAndSettle();

    verify(() => service.reject('p1')).called(1);
    verifyNever(() => service.request(any()));
    expect(find.text('aiOrganize.reject'), findsNothing);
  });
}
