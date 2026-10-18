import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/logic/folder_candidates.dart';
import 'package:appflowy/features/ai_organize/logic/organize_service.dart';
import 'package:appflowy/features/ai_organize/presentation/organize_proposal_view.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/mobile/presentation/bottom_sheet/show_mobile_bottom_sheet.dart';
import 'package:appflowy/mobile/presentation/widgets/show_flowy_mobile_confirm_dialog.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flowy_infra_ui/flowy_infra_ui.dart';
import 'package:flutter/material.dart';

/// Opens the Organize sheet: consent dialog on first use, spinner, then the
/// proposal / error / stale / nothing-to-suggest view. Pass [proposalId] to
/// review an existing proposal (no new request is made).
Future<void> showOrganizeSheet(
  BuildContext context, {
  required String noteId,
  String? proposalId,
}) async {
  final service = await OrganizeService.current();
  if (service == null) {
    showToastNotification(
      message: LocaleKeys.aiOrganize_failed.tr(),
      type: ToastificationType.error,
    );
    return;
  }
  if (proposalId == null && !(await service.state()).consented) {
    if (!context.mounted) return;
    var accepted = false;
    await showFlowyMobileConfirmDialog(
      context,
      title: FlowyText(LocaleKeys.aiOrganize_consentTitle.tr(), maxLines: 2),
      content: FlowyText(
        LocaleKeys.aiOrganize_consentBody.tr(),
        fontSize: 12,
        maxLines: 20,
      ),
      actionButtonTitle: LocaleKeys.aiOrganize_consentAccept.tr(),
      onActionButtonPressed: () => accepted = true,
    );
    // Declining sends nothing.
    if (!accepted) return;
    await service.setConsented();
  }
  if (!context.mounted) return;
  await showMobileBottomSheet<void>(
    context,
    showDragHandle: true,
    showHeader: true,
    title: LocaleKeys.aiOrganize_title.tr(),
    builder: (_) => _OrganizeSheet(
      service: service,
      noteId: noteId,
      proposalId: proposalId,
    ),
  );
}

enum _Phase { working, review, stale, failed, nothing }

class _OrganizeSheet extends StatefulWidget {
  const _OrganizeSheet({
    required this.service,
    required this.noteId,
    this.proposalId,
  });

  final OrganizeService service;
  final String noteId;
  final String? proposalId;

  @override
  State<_OrganizeSheet> createState() => _OrganizeSheetState();
}

class _OrganizeSheetState extends State<_OrganizeSheet> {
  _Phase _phase = _Phase.working;
  OrganizeProposal? _proposal;
  List<FolderCandidate> _candidates = const [];
  OrganizeErrorKind _error = OrganizeErrorKind.failed;
  OrganizeDecision? _lastDecision;

  @override
  void initState() {
    super.initState();
    widget.proposalId == null ? _run() : _load(widget.proposalId!);
  }

  // The request keeps running in the service if the sheet is closed; every
  // post-await UI touch below is guarded by `mounted`.
  Future<void> _run() async {
    setState(() => _phase = _Phase.working);
    try {
      await _show(await widget.service.request(widget.noteId));
    } on OrganizeApiException catch (e) {
      _fail(e.kind);
    } catch (_) {
      _fail(OrganizeErrorKind.failed);
    }
  }

  Future<void> _load(String id) async {
    final s = await widget.service.state();
    if (!mounted) return;
    await _show(s.proposals.where((p) => p.id == id).firstOrNull);
  }

  Future<void> _show(OrganizeProposal? p) async {
    final candidates = p?.state == ProposalState.needsReview
        ? await widget.service.candidatesFor(widget.noteId)
        : const <FolderCandidate>[];
    if (!mounted) return;
    setState(() {
      _proposal = p;
      _candidates = candidates;
      switch (p?.state) {
        case ProposalState.needsReview:
          _phase = _Phase.review;
        case ProposalState.stale:
          _phase = _Phase.stale;
        case ProposalState.failed:
          _error = p!.error ?? OrganizeErrorKind.failed;
          _phase = _Phase.failed;
        default:
          _phase = _Phase.nothing;
      }
    });
  }

  void _fail(OrganizeErrorKind kind) {
    if (!mounted) return;
    setState(() {
      _error = kind;
      _phase = _Phase.failed;
    });
  }

  Future<void> _apply(OrganizeDecision d, {bool force = false}) async {
    final p = _proposal!;
    if (_phase == _Phase.working) return;
    _lastDecision = d;
    setState(() => _phase = _Phase.working);
    ProposalState result;
    try {
      result = await widget.service.apply(p.id, d, force: force);
    } catch (_) {
      result = ProposalState.failed;
    }
    switch (result) {
      case ProposalState.applied:
      case ProposalState.partiallyApplied:
        showToastNotification(message: LocaleKeys.aiOrganize_applied.tr());
      case ProposalState.stale:
        if (mounted) setState(() => _phase = _Phase.stale);
        return;
      default:
        showToastNotification(
          message: LocaleKeys.aiOrganize_failed.tr(),
          type: ToastificationType.error,
        );
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _reject() async {
    final p = _proposal!;
    try {
      await widget.service.reject(p.id);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  String _errorText() => switch (_error) {
        OrganizeErrorKind.unauthorized =>
          LocaleKeys.aiOrganize_signInAgain.tr(),
        OrganizeErrorKind.notInvited => LocaleKeys.aiOrganize_notInvited.tr(),
        OrganizeErrorKind.userLimit => LocaleKeys.aiOrganize_userLimit.tr(),
        OrganizeErrorKind.globalLimit => LocaleKeys.aiOrganize_globalLimit.tr(),
        OrganizeErrorKind.noteMissing => LocaleKeys.aiOrganize_noteMissing.tr(),
        OrganizeErrorKind.tooLarge ||
        OrganizeErrorKind.failed =>
          LocaleKeys.aiOrganize_failed.tr(),
      };

  bool get _canRetry =>
      const {
        OrganizeErrorKind.notInvited,
        OrganizeErrorKind.userLimit,
        OrganizeErrorKind.globalLimit,
      }.contains(_error) ==
      false;

  Widget _message(String text, [List<Widget> actions = const []]) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FlowyText(text, maxLines: 5, textAlign: TextAlign.center),
            for (final a in actions) ...[const SizedBox(height: 12), a],
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _Phase.working:
        return _message(
          LocaleKeys.aiOrganize_working.tr(),
          const [CircularProgressIndicator()],
        );
      case _Phase.review:
        return OrganizeProposalView(
          proposal: _proposal!,
          candidates: _candidates,
          onApply: _apply,
          onReject: _reject,
        );
      case _Phase.stale:
        return _message(LocaleKeys.aiOrganize_stale.tr(), [
          FilledButton(
            onPressed: _run,
            child: Text(LocaleKeys.aiOrganize_rerun.tr()),
          ),
          if (_lastDecision != null)
            OutlinedButton(
              onPressed: () => _apply(_lastDecision!, force: true),
              child: Text(LocaleKeys.aiOrganize_applyAnyway.tr()),
            ),
        ]);
      case _Phase.failed:
        return _message(_errorText(), [
          if (_canRetry)
            FilledButton(
              onPressed: _run,
              child: Text(LocaleKeys.aiOrganize_retry.tr()),
            ),
        ]);
      case _Phase.nothing:
        return _message(LocaleKeys.aiOrganize_nothingToSuggest.tr());
    }
  }
}
