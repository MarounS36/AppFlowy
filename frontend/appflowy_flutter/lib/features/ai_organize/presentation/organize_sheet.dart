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
import 'package:appflowy/features/ai_organize/presentation/organize_errors.dart';
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
  if (!context.mounted) return;
  await showOrganizeSheetFor(
    context,
    service,
    noteId: noteId,
    proposalId: proposalId,
  );
}

/// [showOrganizeSheet] with the service already resolved.
@visibleForTesting
Future<void> showOrganizeSheetFor(
  BuildContext context,
  OrganizeService service, {
  required String noteId,
  String? proposalId,
}) async {
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

enum _Phase { working, review, failed, nothing }

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
    try {
      final s = await widget.service.state();
      if (!mounted) return;
      await _show(s.proposals.where((p) => p.id == id).firstOrNull);
    } catch (_) {
      _fail(OrganizeErrorKind.failed);
    }
  }

  Future<void> _show(OrganizeProposal? p) async {
    final candidates =
        p?.state == ProposalState.needsReview || p?.state == ProposalState.stale
            ? await widget.service.candidatesFor(widget.noteId)
            : const <FolderCandidate>[];
    if (!mounted) return;
    setState(() {
      _proposal = p;
      _candidates = candidates;
      switch (p?.state) {
        case ProposalState.needsReview || ProposalState.stale:
          _phase = _Phase.review;
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
        // The proposal object is now stale; show it with Re-run / Apply anyway.
        if (mounted) setState(() => _phase = _Phase.review);
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

  String _errorText() => organizeErrorKey(_error).tr();

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
        final p = _proposal!;
        final stale = p.state == ProposalState.stale;
        final view = OrganizeProposalView(
          proposal: p,
          candidates: _candidates,
          applyLabel: stale ? LocaleKeys.aiOrganize_applyAnyway.tr() : null,
          onApply: (d) => _apply(d, force: stale),
          onReject: _reject,
        );
        if (!stale) return view;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _message(LocaleKeys.aiOrganize_stale.tr(), [
              OutlinedButton(
                onPressed: _run,
                child: Text(LocaleKeys.aiOrganize_rerun.tr()),
              ),
            ]),
            Flexible(child: view),
          ],
        );
      case _Phase.failed:
        return _message(_errorText(), [
          if (organizeCanRetry(_error))
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
