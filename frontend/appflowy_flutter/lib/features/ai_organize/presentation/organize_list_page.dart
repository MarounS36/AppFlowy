import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/organize_service.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_sheet.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/base/app_bar/app_bar.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Needs review / History list for AI Organize. [service] is for tests.
class OrganizeListPage extends StatefulWidget {
  const OrganizeListPage({
    super.key,
    required this.showHistory,
    @visibleForTesting this.service,
  });

  static const needsReviewRouteName = '/ai-organize/review';
  static const historyRouteName = '/ai-organize/history';

  final bool showHistory;
  final OrganizeService? service;

  @override
  State<OrganizeListPage> createState() => _OrganizeListPageState();
}

class _OrganizeListPageState extends State<OrganizeListPage> {
  OrganizeService? _service;
  OrganizeState? _state;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    OrganizeService? service;
    OrganizeState? state;
    try {
      service = widget.service ?? await OrganizeService.current();
      state = await service?.state();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _service = service;
      _state = state;
      _loaded = true;
    });
  }

  Future<void> _undo(HistoryEntry entry) async {
    final service = _service;
    if (service == null) return;
    try {
      final result = await service.undo(entry.key);
      showToastNotification(
        message: result == UndoResult.conflict
            ? LocaleKeys.aiOrganize_conflict.tr()
            : LocaleKeys.aiOrganize_undone.tr(),
        type: result == UndoResult.conflict
            ? ToastificationType.warning
            : ToastificationType.success,
      );
    } catch (_) {
      showToastNotification(
        message: LocaleKeys.aiOrganize_failed.tr(),
        type: ToastificationType.error,
      );
    }
    if (mounted) await _load();
  }

  Future<void> _review(OrganizeProposal p) async {
    await showOrganizeSheet(context, noteId: p.noteId, proposalId: p.id);
    if (mounted) await _load();
  }

  String _noteTitle(String title) =>
      title.isEmpty ? LocaleKeys.menuAppHeader_defaultNewPageName.tr() : title;

  /// Folder rows name the note ("Groceries: Inbox → Home"); title rows
  /// already do ("old → new").
  String _historyText(HistoryEntry e, Map<String, OrganizeProposal> byId) {
    final change = '${e.beforeLabel} → ${e.afterLabel}';
    if (e.field == OrganizeField.title) return change;
    return '${_noteTitle(byId[e.proposalId]?.snapshot.title ?? '')}: $change';
  }

  String _summary(OrganizeProposal p) {
    final parts = [
      if (p.proposedTitle != null) p.proposedTitle!,
      if (p.proposedFolderPath != null) p.proposedFolderPath!,
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final List<Widget> rows;
    if (state == null) {
      rows = const [];
    } else if (widget.showHistory) {
      final entries = [...state.history]
        ..sort((a, b) => b.appliedAt.compareTo(a.appliedAt));
      final byId = {for (final p in state.proposals) p.id: p};
      rows = [
        for (final e in entries)
          ListTile(
            title: Text(_historyText(e, byId)),
            trailing: e.undone
                ? Text(LocaleKeys.aiOrganize_undone.tr())
                : TextButton(
                    onPressed: () => _undo(e),
                    child: Text(LocaleKeys.aiOrganize_undo.tr()),
                  ),
          ),
      ];
    } else {
      const shown = {
        ProposalState.needsReview,
        ProposalState.stale,
        ProposalState.failed,
      };
      final proposals = state.proposals
          .where((p) => shown.contains(p.state))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      rows = [
        for (final p in proposals)
          ListTile(
            title: Text(_noteTitle(p.snapshot.title)),
            subtitle: Text(_summary(p), maxLines: 1),
            onTap: () => _review(p),
          ),
      ];
    }

    return Scaffold(
      appBar: FlowyAppBar(
        titleText: widget.showHistory
            ? LocaleKeys.aiOrganize_history.tr()
            : LocaleKeys.aiOrganize_needsReview.tr(),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator.adaptive())
          : rows.isEmpty
              ? Center(child: Text(LocaleKeys.aiOrganize_empty.tr()))
              : ListView(children: rows),
    );
  }
}
