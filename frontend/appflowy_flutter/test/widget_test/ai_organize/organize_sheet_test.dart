import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/organize_service.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_sheet.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widget_test_wrapper.dart';

class _MockService extends Mock implements OrganizeService {}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    EasyLocalization.logger.enableLevels = [];
    await EasyLocalization.ensureInitialized();
  });

  late _MockService service;

  setUp(() {
    service = _MockService();
    when(() => service.state())
        .thenAnswer((_) async => OrganizeState());
    when(() => service.setConsented()).thenAnswer((_) async {});
    when(() => service.request(any())).thenAnswer((_) async => null);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () => showOrganizeSheetFor(
              context,
              service,
              noteId: 'n1',
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
}
