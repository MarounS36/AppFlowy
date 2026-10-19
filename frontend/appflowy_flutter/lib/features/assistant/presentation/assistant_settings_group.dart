import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/presentation/assistant_sheet.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/setting/widgets/widgets.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

class AssistantSettingsGroup extends StatefulWidget {
  const AssistantSettingsGroup({super.key});

  @override
  State<AssistantSettingsGroup> createState() => _AssistantSettingsGroupState();
}

class _AssistantSettingsGroupState extends State<AssistantSettingsGroup> {
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
      // Leave the group hidden if the store can't be read.
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    if (service == null) return const SizedBox.shrink();
    return MobileSettingGroup(
      groupTitle: LocaleKeys.assistant_title.tr(),
      settingItemList: [
        MobileSettingItem(
          name: LocaleKeys.assistant_enabled.tr(),
          trailing: Switch.adaptive(
            activeColor: Theme.of(context).colorScheme.primary,
            value: _enabled,
            onChanged: (value) async {
              try {
                await service.setEnabled(value);
              } catch (_) {}
              if (mounted) await _load();
            },
          ),
        ),
        if (_enabled)
          MobileSettingItem(
            name: LocaleKeys.assistant_title.tr(),
            onTap: () => showAssistantSheet(context),
          ),
      ],
    );
  }
}
