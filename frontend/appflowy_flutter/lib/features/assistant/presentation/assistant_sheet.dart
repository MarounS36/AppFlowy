import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/presentation/assistant_view.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/bottom_sheet/show_mobile_bottom_sheet.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Opens Ask InkNest as a full-height bottom sheet on mobile.
Future<void> showAssistantSheet(
  BuildContext context, {
  List<String> pinnedIds = const [],
}) async {
  final service = await AssistantService.current();
  if (service == null) {
    showToastNotification(
      message: LocaleKeys.assistant_failed.tr(),
      type: ToastificationType.error,
    );
    return;
  }
  if (!context.mounted) return;
  await showMobileBottomSheet<void>(
    context,
    showDragHandle: true,
    showHeader: true,
    title: LocaleKeys.assistant_title.tr(),
    builder: (sheetContext) => SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * 0.85 -
          MediaQuery.viewInsetsOf(sheetContext).bottom,
      child: AssistantView(service: service, pinnedIds: pinnedIds),
    ),
  );
}
