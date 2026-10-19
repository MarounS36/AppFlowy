import 'dart:async';

import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:appflowy/features/assistant/logic/mentions.dart';
import 'package:appflowy/features/assistant/presentation/assistant_errors.dart';
import 'package:appflowy/features/assistant/presentation/proposal_preview.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:appflowy/workspace/presentation/widgets/dialogs.dart';
import 'package:appflowy_backend/log.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// Ask InkNest, shared by desktop and mobile: thread, mention chips, input,
/// the open proposal, and the Recent list.
class AssistantView extends StatefulWidget {
  const AssistantView({
    super.key,
    required this.service,
    this.pinnedIds = const [],
  });

  final AssistantService service;
  final List<String> pinnedIds;

  @override
  State<AssistantView> createState() => _AssistantViewState();
}

class _AssistantViewState extends State<AssistantView> {
  final _input = TextEditingController();
  Timer? _debounce;
  AssistantState? _state;
  List<Mentionable> _chips = const [];
  final _removed = <String>{};
  bool _working = false;
  bool _consenting = false;
  bool _askedRaise = false;
  int _chipSeq = 0;
  OrganizeErrorKind? _error;

  AssistantService get _s => widget.service;

  @override
  void initState() {
    super.initState();
    _refresh();
    _updateChips();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final s = await _s.state();
    if (mounted) setState(() => _state = s);
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _updateChips);
  }

  Future<void> _updateChips() async {
    final seq = ++_chipSeq;
    final List<Mentionable> m;
    try {
      m = await _s.mentionsFor(_input.text, pinnedIds: widget.pinnedIds);
    } catch (e) {
      Log.warn('Assistant: mentions failed: $e'); // keep the current chips
      return;
    }
    if (mounted && seq == _chipSeq) {
      setState(
        () => _chips = m.where((e) => !_removed.contains(e.id)).toList(),
      );
    }
  }

  /// First use asks for everything this build can do; Cancel sends nothing.
  /// Someone at a lower stage is asked for the next one once per open view;
  /// "Not now" keeps their stage and sends anyway.
  Future<bool> _consent() async {
    final stage = (await _s.state()).consentedStage;
    if (stage.index >= kBuiltStage.index) return true;
    if (stage == AssistStage.none) {
      if (!await _ask(kBuiltStage, LocaleKeys.button_cancel)) return false;
      await _s.setConsentedStage(kBuiltStage);
      return true;
    }
    if (_askedRaise) return true;
    _askedRaise = true;
    final next = AssistStage.values[stage.index + 1];
    if (await _ask(next, LocaleKeys.assistant_notNow)) {
      await _s.setConsentedStage(next);
    }
    return true;
  }

  Future<bool> _ask(AssistStage stage, String declineKey) async {
    if (!mounted) return false;
    final text = switch (stage) {
      AssistStage.pages => LocaleKeys.assistant_consentStage2,
      AssistStage.workspace => LocaleKeys.assistant_consentStage3,
      _ => LocaleKeys.assistant_consentStage1,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(LocaleKeys.assistant_consentTitle.tr()),
        content: Text(text.tr()),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(declineKey.tr()),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(LocaleKeys.assistant_consentAccept.tr()),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _working) return;
    if (_consenting) return;
    _consenting = true;
    final ok = await _consent();
    _consenting = false;
    if (!ok || !mounted) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final p = await _s.send(text, mentionIds: [for (final c in _chips) c.id]);
      if (!mounted) return;
      _input.clear();
      _removed.clear();
      if (p == null) {
        showToastNotification(message: LocaleKeys.assistant_nothing.tr());
      }
    } on OrganizeApiException catch (e) {
      if (mounted) _error = e.kind;
    } catch (_) {
      if (mounted) _error = OrganizeErrorKind.failed;
    }
    if (!mounted) return;
    setState(() => _working = false);
    await _refresh();
    unawaited(_updateChips());
  }

  Future<void> _run(Future<void> Function() job) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await job();
    } on OrganizeApiException catch (e) {
      _toastError(assistantErrorKey(e.kind));
    } catch (_) {
      _toastError(LocaleKeys.assistant_failed);
    }
    if (!mounted) return;
    setState(() => _working = false);
    await _refresh();
  }

  void _toastError(String key) =>
      showToastNotification(message: key.tr(), type: ToastificationType.error);

  void _toastApplied(AppliedProposal r) {
    final total = r.actions.length;
    final msg = r.status == AppliedStatus.applied
        ? LocaleKeys.assistant_done.tr(args: ['$total'])
        : LocaleKeys.assistant_appliedPartial
            .tr(args: ['${r.records.length}', '$total']);
    showToastNotification(message: msg);
  }

  Future<void> _apply(Set<int> ticked, Map<int, Map<String, dynamic>> edits) =>
      _run(() async {
        final p = _state!.proposal!;
        p.ticked = ticked;
        p.edits = edits;
        final r = await _s.apply();
        if (mounted) _toastApplied(r);
      });

  Future<void> _undo(String id) => _run(() async {
        final r = await _s.undo(id);
        if (!mounted) return;
        showToastNotification(
          message: LocaleKeys.assistant_undone.tr(
            args: ['${r.reverted}', '${r.skippedChanged + r.skippedGone}'],
          ),
        );
      });

  Future<void> _retry(String id) => _run(() async {
        final r = await _s.retry(id);
        if (mounted) _toastApplied(r);
      });

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final proposal = s?.proposal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final t in s?.thread ?? const <ChatTurn>[])
                Align(
                  alignment: t.role == 'user'
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(t.text),
                  ),
                ),
              if (proposal != null) ...[
                const Divider(),
                ProposalPreview(
                  key: ValueKey(proposal.id),
                  proposal: proposal,
                  describe: (a) => _s.describe(a, proposal.labels),
                  onApply: _apply,
                ),
                TextButton(
                  onPressed: _working ? null : () => _run(_s.discard),
                  child: Text(LocaleKeys.assistant_discard.tr()),
                ),
              ],
              if (s != null && s.applied.isNotEmpty) ...[
                const Divider(),
                Text(LocaleKeys.assistant_recent.tr()),
                for (final a in s.applied.reversed) _recentRow(a),
              ],
            ],
          ),
        ),
        if (_working)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(LocaleKeys.assistant_working.tr()),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    assistantErrorKey(_error!).tr(),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
                if (assistantCanRetry(_error!))
                  TextButton(
                    onPressed: _send,
                    child: Text(LocaleKeys.assistant_retry.tr()),
                  ),
              ],
            ),
          ),
        _composer(),
      ],
    );
  }

  Widget _recentRow(AppliedProposal a) {
    final text = [
      for (final x in a.actions.take(2)) _s.describe(x, a.labels).text,
    ].join(', ');
    return Row(
      children: [
        Expanded(
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        if (a.status == AppliedStatus.partial ||
            a.status == AppliedStatus.applying)
          TextButton(
            onPressed: _working ? null : () => _retry(a.id),
            child: Text(LocaleKeys.assistant_retry.tr()),
          ),
        if (a.status != AppliedStatus.undone)
          TextButton(
            onPressed: _working ? null : () => _undo(a.id),
            child: Text(LocaleKeys.assistant_undo.tr()),
          ),
      ],
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_chips.isNotEmpty)
            Wrap(
              spacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(LocaleKeys.assistant_using.tr()),
                for (final c in _chips)
                  InputChip(
                    label: Text(c.name),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    onDeleted: () => setState(() {
                      _removed.add(c.id);
                      _chips = _chips.where((e) => e.id != c.id).toList();
                    }),
                  ),
              ],
            ),
          Wrap(
            spacing: 6,
            children: [
              for (final (label, _) in [
                (LocaleKeys.assistant_planWeek, 0),
                (LocaleKeys.assistant_newBoard, 1),
                (LocaleKeys.assistant_newPage, 2),
              ])
                ActionChip(
                  label: Text(label.tr()),
                  onPressed: () {
                    _input.text = label.tr();
                    _onChanged(_input.text);
                  },
                ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  onChanged: _onChanged,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: LocaleKeys.assistant_placeholder.tr(),
                  ),
                ),
              ),
              TextButton(
                onPressed: _working ? null : _send,
                child: Text(LocaleKeys.assistant_send.tr()),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
