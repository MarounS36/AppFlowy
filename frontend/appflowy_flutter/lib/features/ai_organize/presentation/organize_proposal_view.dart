import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/folder_candidates.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/bottom_sheet/show_mobile_bottom_sheet.dart';
import 'package:appflowy/mobile/presentation/widgets/flowy_option_tile.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flowy_infra_ui/flowy_infra_ui.dart';
import 'package:flutter/material.dart';

/// Pure view of a proposal: a row (with its own accept checkbox) for each
/// non-null proposed field, the reason, and Apply selected / Reject.
class OrganizeProposalView extends StatefulWidget {
  const OrganizeProposalView({
    super.key,
    required this.proposal,
    required this.candidates,
    required this.onApply,
    required this.onReject,
    this.applyLabel,
  });

  final OrganizeProposal proposal;
  final List<FolderCandidate> candidates;
  final ValueChanged<OrganizeDecision> onApply;
  final VoidCallback onReject;

  /// Overrides the Apply button text (e.g. "Apply anyway" for a stale proposal).
  final String? applyLabel;

  @override
  State<OrganizeProposalView> createState() => _OrganizeProposalViewState();
}

class _OrganizeProposalViewState extends State<OrganizeProposalView> {
  late final TextEditingController _title =
      TextEditingController(text: widget.proposal.proposedTitle);
  late String? _folderId = widget.proposal.proposedFolderId;
  late String? _folderPath = widget.proposal.proposedFolderPath;
  late bool _titleChecked = widget.proposal.proposedTitle != null;
  late bool _folderChecked = widget.proposal.proposedFolderId != null;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  OrganizeDecision get _decision {
    final title = _title.text.trim();
    return OrganizeDecision(
      title: _titleChecked && title.isNotEmpty ? title : null,
      folderId: _folderChecked ? _folderId : null,
    );
  }

  void _apply() => widget.onApply(_decision);

  Future<void> _chooseFolder() async {
    final picked = await showMobileBottomSheet<FolderCandidate>(
      context,
      showHeader: true,
      showDragHandle: true,
      showDivider: false,
      title: LocaleKeys.aiOrganize_folderRow.tr(),
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (i, c) in widget.candidates.indexed)
            FlowyOptionTile.checkbox(
              text: c.path,
              showTopBorder: i == 0,
              isSelected: c.id == _folderId,
              onTap: () => Navigator.of(sheetContext).pop(c),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _folderId = picked.id;
        _folderPath = picked.path;
        _folderChecked = true;
      });
    }
  }

  // FlowyOptionTile.checkbox drops `text` when `content` is given.
  Widget _rowContent(String label, List<Widget> details) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [FlowyText(label), ...details],
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (p.proposedTitle != null) ...[
            FlowyOptionTile.checkbox(
              text: LocaleKeys.aiOrganize_titleRow.tr(),
              isSelected: _titleChecked,
              onTap: () => setState(() => _titleChecked = !_titleChecked),
              content: _rowContent(
                LocaleKeys.aiOrganize_titleRow.tr(),
                [
                  FlowyText(
                    p.snapshot.title,
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ],
              ),
            ),
            FlowyOptionTile.textField(
              controller: _title,
              showTopBorder: false,
              onTextChanged: (_) => setState(() => _titleChecked = true),
            ),
          ],
          if (p.proposedFolderId != null)
            FlowyOptionTile.checkbox(
              text: LocaleKeys.aiOrganize_folderRow.tr(),
              isSelected: _folderChecked,
              onTap: () => setState(() => _folderChecked = !_folderChecked),
              content: _rowContent(
                LocaleKeys.aiOrganize_folderRow.tr(),
                [
                  FlowyText(
                    '${p.currentFolderPath} → ${_folderPath ?? ''}',
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                    maxLines: 3,
                  ),
                  TextButton(
                    onPressed: _chooseFolder,
                    child: Text(LocaleKeys.aiOrganize_chooseAnother.tr()),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FlowyText(
              p.reason,
              fontSize: 12,
              color: Theme.of(context).hintColor,
              maxLines: 6,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: widget.onReject,
                    child: Text(LocaleKeys.aiOrganize_reject.tr()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed:
                        _decision.title == null && _decision.folderId == null
                            ? null
                            : _apply,
                    child: Text(
                      widget.applyLabel ??
                          LocaleKeys.aiOrganize_applySelected.tr(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
