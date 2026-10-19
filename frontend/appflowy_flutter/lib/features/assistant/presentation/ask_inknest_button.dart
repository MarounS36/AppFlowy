import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/presentation/assistant_availability_builder.dart';
import 'package:appflowy/features/assistant/presentation/assistant_dialog.dart';
import 'package:appflowy/generated/flowy_svgs.g.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/workspace/presentation/widgets/toggle/toggle.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flowy_infra_ui/flowy_infra_ui.dart';
import 'package:flutter/material.dart';

/// Page-header button; hidden unless Ask InkNest is available.
class AskInkNestButton extends StatelessWidget {
  const AskInkNestButton({super.key, this.pinnedIds = const []});

  final List<String> pinnedIds;

  @override
  Widget build(BuildContext context) {
    return AssistantAvailabilityBuilder(
      builder: (_) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: FlowyTooltip(
          message: LocaleKeys.assistant_title.tr(),
          child: FlowyIconButton(
            width: 28,
            height: 28,
            icon: const FlowySvg(FlowySvgs.ai_sparks_s),
            onPressed: () async {
              if (!await AssistantService.isAvailable()) return;
              if (!context.mounted) return;
              await showAssistantDialog(context, pinnedIds: pinnedIds);
            },
          ),
        ),
      ),
    );
  }
}

/// Settings -> AI row; hidden when the assistant isn't configured.
class AssistantSettingsToggle extends StatefulWidget {
  const AssistantSettingsToggle({super.key});

  @override
  State<AssistantSettingsToggle> createState() =>
      _AssistantSettingsToggleState();
}

class _AssistantSettingsToggleState extends State<AssistantSettingsToggle> {
  AssistantService? _service;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final service = await AssistantService.current();
      final state = await service?.state();
      if (!mounted || service == null || state == null) return;
      setState(() {
        _service = service;
        _enabled = state.enabled;
      });
    } catch (_) {
      // Leave the row hidden if the store can't be read.
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    if (service == null) return const SizedBox.shrink();
    return Row(
      children: [
        FlowyText.medium(LocaleKeys.assistant_enabled.tr()),
        const Spacer(),
        Toggle(
          value: _enabled,
          onChanged: (_) async {
            try {
              await service.setEnabled(!_enabled);
            } catch (_) {}
            if (mounted) await _load();
          },
        ),
      ],
    );
  }
}
