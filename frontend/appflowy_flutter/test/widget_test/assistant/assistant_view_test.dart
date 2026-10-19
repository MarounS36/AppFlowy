import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/logic/mentions.dart';
import 'package:appflowy/features/assistant/presentation/assistant_view.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:appflowy_ui/appflowy_ui.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockService extends Mock implements AssistantService {}

void main() {
  setUpAll(() async {
    registerFallbackValue(AssistStage.none);
    registerFallbackValue(AssistAction(type: 't', fields: {}));
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableLevels = [];
    await EasyLocalization.ensureInitialized();
  });

  late _MockService service;

  setUp(() {
    service = _MockService();
    when(() => service.state()).thenAnswer((_) async => AssistantState());
    when(() => service.setConsentedStage(any())).thenAnswer((_) async {});
    when(
      () => service.mentionsFor(any(), pinnedIds: any(named: 'pinnedIds')),
    ).thenAnswer(
      (_) async => const [
        Mentionable(id: 'b1', name: 'Move', kind: 'board'),
        Mentionable(id: 'b2', name: 'Trip', kind: 'board'),
      ],
    );
    when(() => service.send(any(), mentionIds: any(named: 'mentionIds')))
        .thenAnswer((_) async => null);
  });

  /// Toasts build with the theme above the app, so it wraps ToastificationWrapper.
  Widget themed(Widget child) => AppFlowyTheme(
        data: AppFlowyDefaultTheme().light(),
        child: ToastificationWrapper(
          child: MaterialApp(home: Material(child: child)),
        ),
      );

  Proposal openProposal() => Proposal(
        id: 'p1',
        actions: [
          AssistAction(type: 'add', fields: {'title': 'Gym'}),
          AssistAction(type: 'add', fields: {'title': 'Dentist'}),
        ],
        note: '',
        weekStart: '2026-10-19',
        labels: {},
        ticked: {0, 1},
      );

  Future<void> pumpConsented(WidgetTester tester) async {
    await tester.pumpWidget(themed(AssistantView(service: service)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'hello');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('assistant.send'));
    await tester.pump();
    await tester.pump();
  }

  void consented([AssistStage stage = AssistStage.pages]) =>
      when(() => service.state()).thenAnswer(
        (_) async => AssistantState(consentedStage: stage),
      );

  testWidgets('a limit error shows its text and no Retry', (tester) async {
    consented();
    when(() => service.send(any(), mentionIds: any(named: 'mentionIds')))
        .thenThrow(const OrganizeApiException(OrganizeErrorKind.userLimit));
    await pumpConsented(tester);
    expect(find.text('assistant.userLimit'), findsOneWidget);
    expect(find.text('assistant.retry'), findsNothing);
  });

  testWidgets('a failed send shows Retry, which sends again', (tester) async {
    consented();
    when(() => service.send(any(), mentionIds: any(named: 'mentionIds')))
        .thenThrow(const OrganizeApiException(OrganizeErrorKind.failed));
    await pumpConsented(tester);
    expect(find.text('assistant.failed'), findsOneWidget);
    await tester.tap(find.text('assistant.retry'));
    await tester.pump();
    await tester.pump();
    verify(() => service.send('hello', mentionIds: any(named: 'mentionIds')))
        .called(2);
  });

  testWidgets('nothing to change shows a toast', (tester) async {
    consented();
    await pumpConsented(tester);
    verify(() => service.send('hello', mentionIds: any(named: 'mentionIds')))
        .called(1);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('assistant.nothing', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Apply writes ticked + edits onto the proposal, then applies',
      (tester) async {
    final p = openProposal();
    when(() => service.state()).thenAnswer(
      (_) async => AssistantState(
        consentedStage: AssistStage.schedule,
        proposal: p,
      ),
    );
    when(() => service.describe(any(), any())).thenAnswer(
      (i) => ActionPreview(
        text: (i.positionalArguments[0] as AssistAction).fields['title'],
        editable: const ['title'],
      ),
    );
    Set<int>? tickedAtCall;
    Map<int, Map<String, dynamic>>? editsAtCall;
    when(() => service.apply()).thenAnswer((_) async {
      tickedAtCall = {...p.ticked};
      editsAtCall = {...p.edits};
      return AppliedProposal(
        id: 'p1',
        appliedAt: DateTime(2026),
        actions: [p.actions[1]],
        status: AppliedStatus.applied,
      );
    });
    await tester.pumpWidget(themed(AssistantView(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.enterText(find.byType(TextField).at(1), 'Dentist 5pm');
    await tester.tap(find.text('assistant.applySelected'));
    await tester.pump();
    await tester.pump();
    expect(tickedAtCall, {1});
    expect(editsAtCall, {
      1: {'title': 'Dentist 5pm'},
    });
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Discard calls the service', (tester) async {
    final p = openProposal();
    when(() => service.state()).thenAnswer(
      (_) async => AssistantState(proposal: p),
    );
    when(() => service.describe(any(), any()))
        .thenReturn(const ActionPreview(text: 'x'));
    when(() => service.discard()).thenAnswer((_) async {});
    await tester.pumpWidget(themed(AssistantView(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('assistant.discard'));
    await tester.pump();
    verify(() => service.discard()).called(1);
  });

  Future<void> typeAndSend(WidgetTester tester) async {
    await tester.pumpWidget(
      themed(AssistantView(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'move and trip');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('assistant.send'));
    await tester.pumpAndSettle();
  }

  testWidgets('removing a chip excludes its id from send', (tester) async {
    consented();
    await tester.pumpWidget(
      themed(AssistantView(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'move and trip');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Move'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(InputChip, 'Move'),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('assistant.send'));
    await tester.pumpAndSettle();
    verify(() => service.send('move and trip', mentionIds: ['b2'])).called(1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('declining consent sends nothing', (tester) async {
    await typeAndSend(tester);
    expect(find.text('assistant.consentTitle'), findsOneWidget);
    await tester.tap(find.text('button.cancel'));
    await tester.pumpAndSettle();
    verifyNever(() => service.setConsentedStage(any()));
    verifyNever(
      () => service.send(any(), mentionIds: any(named: 'mentionIds')),
    );
  });

  testWidgets('accepting first-use consent grants the built stage, then sends',
      (tester) async {
    await typeAndSend(tester);
    await tester.tap(find.text('assistant.consentAccept'));
    await tester.pumpAndSettle();
    verifyInOrder([
      () => service.setConsentedStage(kBuiltStage),
      () => service.send('move and trip', mentionIds: ['b1', 'b2']),
    ]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('stage 2 consent: Continue records pages, then sends',
      (tester) async {
    consented(AssistStage.schedule);
    await typeAndSend(tester);
    expect(find.text('assistant.consentStage2'), findsOneWidget);
    await tester.tap(find.text('assistant.consentAccept'));
    await tester.pumpAndSettle();
    verifyInOrder([
      () => service.setConsentedStage(AssistStage.pages),
      () => service.send('move and trip', mentionIds: ['b1', 'b2']),
    ]);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('stage 2 consent: Not now keeps stage 1, sends, asks once',
      (tester) async {
    consented(AssistStage.schedule);
    await typeAndSend(tester);
    expect(find.text('button.cancel'), findsNothing);
    await tester.tap(find.text('assistant.notNow'));
    await tester.pumpAndSettle();
    verifyNever(() => service.setConsentedStage(any()));
    verify(() => service.send('move and trip', mentionIds: ['b1', 'b2']))
        .called(1);
    await tester.pump(const Duration(seconds: 5));

    await tester.enterText(find.byType(TextField), 'again');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('assistant.send'));
    await tester.pumpAndSettle();
    expect(find.text('assistant.consentStage2'), findsNothing);
    verify(() => service.send('again', mentionIds: any(named: 'mentionIds')))
        .called(1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('first use shows the built stage text with Cancel',
      (tester) async {
    expect(kBuiltStage, AssistStage.pages);
    await typeAndSend(tester);
    expect(find.text('assistant.consentStage2'), findsOneWidget);
    expect(find.text('assistant.consentStage1'), findsNothing);
    expect(find.text('button.cancel'), findsOneWidget);
    expect(find.text('assistant.notNow'), findsNothing);
  });

  testWidgets('a failed mention lookup keeps the current chips',
      (tester) async {
    consented();
    await tester.pumpWidget(themed(AssistantView(service: service)));
    await tester.pumpAndSettle();
    expect(find.text('Move'), findsOneWidget);
    when(
      () => service.mentionsFor(any(), pinnedIds: any(named: 'pinnedIds')),
    ).thenThrow(Exception('backend'));
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Move'), findsOneWidget);
  });

  testWidgets('New page chip fills the input', (tester) async {
    consented();
    await tester.pumpWidget(themed(AssistantView(service: service)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('assistant.newPage'));
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'assistant.newPage',
    );
  });
}
