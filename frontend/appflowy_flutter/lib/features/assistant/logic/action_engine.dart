import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';

class UndoReport {
  const UndoReport({
    required this.reverted,
    required this.skippedChanged,
    required this.skippedGone,
  });

  final int reverted, skippedChanged, skippedGone;
}

class ActionEngine {
  ActionEngine(List<ActionHandler> handlers)
      : _handlers = {for (final h in handlers) h.type: h};

  final Map<String, ActionHandler> _handlers;

  /// Keeps, in order, the actions a handler exists for, allowed at [stage],
  /// and valid given the temp ids declared by earlier kept actions.
  List<AssistAction> filterValid(
    List<AssistAction> actions, {
    required ValidationScope scope,
    required AssistStage stage,
  }) {
    final s = ValidationScope(
      knownIds: scope.knownIds,
      weekStart: scope.weekStart,
      readOnlyIds: scope.readOnlyIds,
      items: scope.items,
      boundTemps: {...scope.boundTemps},
    );
    final kept = <AssistAction>[];
    for (final a in actions) {
      final h = _handlers[a.type];
      if (h == null || h.stage.index > stage.index) continue;
      try {
        if (h.validate(a, s) != null) continue;
      } catch (_) {
        continue; // malformed server JSON
      }
      kept.add(a);
      s.boundTemps.addAll(_declaredTemps(a));
    }
    return kept;
  }

  /// Sent as `allowed_actions`.
  List<String> typesUpTo(AssistStage stage) => [
        for (final h in _handlers.values)
          if (h.stage.index <= stage.index) h.type,
      ]..sort();

  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      _handlers[a.type]!.describe(a, labels);

  /// Resumes at `p.records.length`; stops on the first failure (status
  /// partial). Never rethrows.
  Future<void> apply(
    AppliedProposal p, {
    Future<void> Function()? onProgress,
  }) async {
    if (p.status == AppliedStatus.applied || p.status == AppliedStatus.undone) {
      return;
    }
    p.status = AppliedStatus.applying;
    final scope = ApplyScope(p.tempIds);
    for (var i = p.records.length; i < p.actions.length; i++) {
      final a = p.actions[i];
      try {
        p.records.add(await _handlers[a.type]!.apply(a, scope));
      } catch (e) {
        p.status = AppliedStatus.partial;
        p.error = e.toString();
        return;
      }
      await onProgress?.call();
    }
    p.status = AppliedStatus.applied;
    p.error = null;
  }

  /// Reverse order; a handler that throws counts as skippedChanged.
  Future<UndoReport> undo(AppliedProposal p) async {
    final counts = {for (final o in UndoOutcome.values) o: 0};
    if (p.status != AppliedStatus.undone) {
      for (final r in p.records.reversed) {
        UndoOutcome o;
        try {
          o = await _handlers[r.type]!.undo(r);
        } catch (_) {
          o = UndoOutcome.skippedChanged;
        }
        counts[o] = counts[o]! + 1;
      }
      p.status = AppliedStatus.undone;
    }
    return UndoReport(
      reverted: counts[UndoOutcome.reverted]!,
      skippedChanged: counts[UndoOutcome.skippedChanged]!,
      skippedGone: counts[UndoOutcome.skippedGone]!,
    );
  }
}

/// `temp_id` plus nested ones in `columns` (board.create) and `fields`
/// (database.create).
Iterable<String> _declaredTemps(AssistAction a) sync* {
  if (a.fields['temp_id'] case final String t) yield t;
  for (final key in const ['columns', 'fields']) {
    if (a.fields[key] case final List list) {
      for (final e in list) {
        if (e case {'temp_id': final String t}) yield t;
      }
    }
  }
}
