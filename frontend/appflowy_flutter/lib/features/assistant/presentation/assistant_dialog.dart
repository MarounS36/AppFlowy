import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/presentation/assistant_view.dart';
import 'package:appflowy/generated/flowy_svgs.g.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:appflowy_ui/appflowy_ui.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Opens Ask InkNest in a modal on desktop.
Future<void> showAssistantDialog(
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
  final theme = AppFlowyTheme.of(context);
  await showDialog(
    context: context,
    barrierColor: theme.surfaceColorScheme.overlay,
    builder: (dialogContext) => AFModal(
      constraints: BoxConstraints(maxWidth: AFModalDimension.L, maxHeight: 640),
      child: Column(
        children: [
          AFModalHeader(
            leading: Text(
              LocaleKeys.assistant_title.tr(),
              style: theme.textStyle.heading4.standard(
                color: theme.textColorScheme.primary,
              ),
            ),
            trailing: [
              AFGhostButton.normal(
                onTap: () => Navigator.of(dialogContext).pop(),
                padding: EdgeInsets.all(theme.spacing.xs),
                builder: (_, __, ___) => const FlowySvg(
                  FlowySvgs.toast_close_s,
                  size: Size.square(20),
                ),
              ),
            ],
          ),
          Expanded(
            child: AFModalBody(
              child: AssistantView(service: service, pinnedIds: pinnedIds),
            ),
          ),
        ],
      ),
    ),
  );
}
