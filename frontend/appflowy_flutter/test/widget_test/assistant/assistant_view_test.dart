import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/logic/mentions.dart';
import 'package:appflowy/features/assistant/presentation/assistant_view.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widget_test_wrapper.dart';

class _MockService extends Mock implements AssistantService {}

void main() {
  setUpAll(() async {
    registerFallbackValue(AssistStage.none);
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
        .thenAnswer(
      // A proposal (not null) so no "nothing to change" toast, which needs a
      // theme the test harness lacks.
      (_) async => Proposal(
        id: 'p',
        actions: [],
        note: '',
        weekStart: '2026-10-19',
        labels: {},
      ),
    );
  });

  Future<void> typeAndSend(WidgetTester tester) async {
    await tester.pumpWidget(
      WidgetTestWrapper(child: AssistantView(service: service)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'move and trip');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('assistant.send'));
    await tester.pumpAndSettle();
  }

  testWidgets('removing a chip excludes its id from send', (tester) async {
    when(() => service.state()).thenAnswer(
      (_) async => AssistantState(consentedStage: AssistStage.schedule),
    );
    await tester.pumpWidget(
      WidgetTestWrapper(child: AssistantView(service: service)),
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

  testWidgets('accepting consent records it, then sends', (tester) async {
    await typeAndSend(tester);
    await tester.tap(find.text('assistant.consentAccept'));
    await tester.pumpAndSettle();
    verifyInOrder([
      () => service.setConsentedStage(AssistStage.schedule),
      () => service.send('move and trip', mentionIds: ['b1', 'b2']),
    ]);
  });
}
