import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/organize_service.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_list_page.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/setting/widgets/widgets.dart';
import 'package:appflowy/mobile/presentation/setting/widgets/mobile_setting_trailing.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AiOrganizeSettingsGroup extends StatefulWidget {
  const AiOrganizeSettingsGroup({super.key});

  @override
  State<AiOrganizeSettingsGroup> createState() =>
      _AiOrganizeSettingsGroupState();
}

class _AiOrganizeSettingsGroupState extends State<AiOrganizeSettingsGroup> {
  OrganizeService? _service;
  OrganizeState? _state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final service = await OrganizeService.current();
      final state = await service?.state();
      if (!mounted) return;
      setState(() {
        _service = service;
        _state = state;
      });
    } catch (_) {
      // Leave the group hidden if the store can't be read.
    }
  }

  Future<void> _push(String route) async {
    await context.push(route);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final service = _service;
    final state = _state;
    if (service == null || state == null) return const SizedBox.shrink();

    final pending = state.proposals
        .where(
          (p) => const {
            ProposalState.needsReview,
            ProposalState.stale,
            ProposalState.failed,
          }.contains(p.state),
        )
        .length;

    return MobileSettingGroup(
      groupTitle: LocaleKeys.aiOrganize_title.tr(),
      settingItemList: [
        MobileSettingItem(
          name: LocaleKeys.aiOrganize_enabled.tr(),
          trailing: Switch.adaptive(
            activeColor: Theme.of(context).colorScheme.primary,
            value: state.enabled,
            onChanged: (value) async {
              try {
                await service.setEnabled(value);
              } catch (_) {}
              if (mounted) await _load();
            },
          ),
        ),
        MobileSettingItem(
          name: LocaleKeys.aiOrganize_needsReview.tr(),
          trailing: MobileSettingTrailing(text: '$pending'),
          onTap: () => _push(OrganizeListPage.needsReviewRouteName),
        ),
        MobileSettingItem(
          name: LocaleKeys.aiOrganize_history.tr(),
          onTap: () => _push(OrganizeListPage.historyRouteName),
        ),
      ],
    );
  }
}
