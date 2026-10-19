import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy/features/assistant/presentation/proposal_preview.dart';
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

  AssistAction act(String type, String title) =>
      AssistAction(type: type, fields: {'title': title});

  final proposal = Proposal(
    id: 'p1',
    actions: [act('add', 'Gym'), act('add', 'Dentist'), act('remove', 'Old')],
    note: 'n',
    weekStart: '2026-10-19',
    labels: const {},
    ticked: {0, 1},
  );

  ActionPreview describe(AssistAction a) => ActionPreview(
        text: '${a.type} ${a.fields['title']}',
        destructive: a.type == 'remove',
        editable: a.type == 'add' ? const ['title'] : const [],
      );

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
        WidgetTestWrapper(
          child: ProposalPreview(
            proposal: proposal,
            describe: describe,
            onApply: (_, __) {},
          ),
        ),
      );

  testWidgets('destructive row is error-coloured and starts unticked',
      (tester) async {
    await pump(tester);
    final text = tester.widget<Text>(find.text('remove Old'));
    final context = tester.element(find.text('remove Old'));
    expect(text.style?.color, Theme.of(context).colorScheme.error);
    final boxes = tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
    expect([for (final b in boxes) b.value], [true, true, false]);
  });

  testWidgets('only ticked indexes reach onApply', (tester) async {
    Set<int>? got;
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: ProposalPreview(
          proposal: proposal,
          describe: describe,
          onApply: (t, _) => got = t,
        ),
      ),
    );
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.tap(find.byType(Checkbox).at(2));
    await tester.pump();
    await tester.tap(find.text('assistant.applySelected'));
    expect(got, {0, 2});
  });

  testWidgets('editing a title passes edits[i][title]', (tester) async {
    Map<int, Map<String, dynamic>>? got;
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: ProposalPreview(
          proposal: proposal,
          describe: describe,
          onApply: (_, e) => got = e,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).first, 'Gym 7am');
    await tester.tap(find.text('assistant.applySelected'));
    expect(got, {
      0: {'title': 'Gym 7am'},
    });
  });

  testWidgets('a content box is multi-line and keeps newlines', (tester) async {
    Map<int, Map<String, dynamic>>? got;
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: ProposalPreview(
          proposal: Proposal(
            id: 'p3',
            actions: [
              AssistAction(type: 'page.append', fields: {'content': 'Hi'}),
            ],
            note: '',
            weekStart: '2026-10-19',
            labels: const {},
          ),
          describe: (_) =>
              const ActionPreview(text: 'x', editable: ['content']),
          onApply: (_, e) => got = e,
        ),
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.maxLines, isNull);
    expect(field.minLines, 3);
    expect(field.keyboardType, TextInputType.multiline);
    await tester.enterText(find.byType(TextField), '# Notes\n- one\n- two');
    await tester.tap(find.text('assistant.applySelected'));
    expect(got, {
      0: {'content': '# Notes\n- one\n- two'},
    });
  });

  testWidgets('a cell box starts with its value and is named for its field',
      (tester) async {
    await tester.pumpWidget(
      WidgetTestWrapper(
        child: ProposalPreview(
          proposal: Proposal(
            id: 'p2',
            actions: [
              AssistAction(
                type: 'row.add',
                fields: {
                  'cells': {'f1': 'Dune'},
                },
              ),
            ],
            note: '',
            weekStart: '2026-10-19',
            labels: const {'f1': 'Title'},
          ),
          describe: (_) => const ActionPreview(text: 'x', editable: ['f1']),
          onApply: (_, __) {},
        ),
      ),
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Dune');
    expect(field.decoration!.labelText, 'Title');
  });
}
