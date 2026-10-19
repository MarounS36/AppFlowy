import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/presentation/assistant_availability_builder.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('hides live when availability turns false', (tester) async {
    AssistantService.availability.value = true;
    await tester.pumpWidget(
      MaterialApp(
        home: AssistantAvailabilityBuilder(
          builder: (_) => const Text('ask'),
        ),
      ),
    );
    // isAvailable() in initState fails in tests (no backend) and is swallowed.
    await tester.pump();
    AssistantService.availability.value = true;
    await tester.pump();
    expect(find.text('ask'), findsOneWidget);

    AssistantService.availability.value = false;
    await tester.pump();
    expect(find.text('ask'), findsNothing);
  });
}
