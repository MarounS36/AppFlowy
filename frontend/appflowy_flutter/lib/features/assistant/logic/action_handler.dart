import 'package:appflowy/features/assistant/data/assistant_models.dart';

/// What the proposal UI shows for one action.
class ActionPreview {
  const ActionPreview({
    required this.text,
    this.before,
    this.after,
    this.destructive = false,
    this.editable = const [],
  });

  final String text;
  final String? before;
  final String? after;
  final bool destructive;

  /// Field keys the UI may edit.
  final List<String> editable;
}

enum UndoOutcome { reverted, skippedChanged, skippedGone }

/// Temp ids (`new:N`) the AI uses for things created earlier in the same
/// proposal, bound to real ids as they are created. Shared across one apply.
class ApplyScope {
  ApplyScope(this.tempIds);

  final Map<String, String> tempIds;

  /// `new:N` → its real id, any other id unchanged. Throws [StateError] for an
  /// unbound temp id so the action fails instead of writing with a bogus id.
  String resolve(String id) {
    if (!id.startsWith('new:')) return id;
    return tempIds[id] ?? (throw StateError('Unbound temp id $id'));
  }

  void bind(String tempId, String realId) => tempIds[tempId] = realId;
}

/// What a handler may check an action against.
class ValidationScope {
  ValidationScope({
    required this.knownIds,
    required this.weekStart,
    Set<String>? readOnlyIds,
    Map<String, Map<String, dynamic>>? items,
    Set<String>? boundTemps,
  })  : readOnlyIds = readOnlyIds ?? const {},
        items = items ?? const {},
        boundTemps = boundTemps ?? {};

  /// Ids sent in context.
  final Set<String> knownIds;

  /// Monday 00:00 local.
  final DateTime weekStart;

  /// Non-editable boards, locked pages, non-writable fields.
  final Set<String> readOnlyIds;

  /// id → that item's context JSON (e.g. a field's type). The engine adds
  /// `{'created_by': <action type>}` for each kept action's own `temp_id`.
  final Map<String, Map<String, dynamic>> items;

  /// Temp ids declared by earlier kept actions (the engine fills it).
  final Set<String> boundTemps;
}

/// What each domain's context builder returns.
class ContextPart {
  const ContextPart({
    required this.json,
    required this.labels,
    required this.ids,
    this.readOnlyIds = const {},
    this.items = const {},
  });

  final Map<String, dynamic> json;
  final Map<String, String> labels;
  final Set<String> ids;
  final Set<String> readOnlyIds;
  final Map<String, Map<String, dynamic>> items;
}

abstract class ActionHandler {
  String get type;

  /// Lowest consent stage at which this action may be offered.
  AssistStage get stage;

  /// Null = valid, else why not.
  String? validate(AssistAction a, ValidationScope scope);

  ActionPreview describe(AssistAction a, Map<String, String> labels);

  /// All-or-nothing: on failure, roll back your own writes, bind nothing, and
  /// throw. Call [ApplyScope.bind] only after the write succeeded. Return
  /// exactly one record, with `type == this.type`.
  Future<UndoRecord> apply(AssistAction a, ApplyScope scope);

  /// Must be idempotent: a crash mid-undo can run it again on the same record.
  Future<UndoOutcome> undo(UndoRecord r);
}
