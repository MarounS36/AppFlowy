/// How much of the workspace the user has consented to share; index = stage.
enum AssistStage { none, schedule, pages, workspace }

enum AppliedStatus { applying, applied, partial, undone }

T _enum<T extends Enum>(List<T> values, Object? name) =>
    values.firstWhere((e) => e.name == name);

class AssistAction {
  AssistAction({required this.type, required this.fields});

  factory AssistAction.fromJson(Map<String, dynamic> json) => AssistAction(
        type: json['type'] as String,
        fields: Map<String, dynamic>.from(json['fields'] as Map),
      );

  final String type;

  /// Raw action JSON from the server (snake_case keys), kept untouched.
  final Map<String, dynamic> fields;

  String? get tempId => fields['temp_id'] as String?;

  Map<String, dynamic> toJson() => {'type': type, 'fields': fields};
}

class ChatTurn {
  ChatTurn({required this.role, required this.text});

  factory ChatTurn.fromJson(Map<String, dynamic> json) =>
      ChatTurn(role: json['role'] as String, text: json['text'] as String);

  /// 'user' or 'assistant'.
  final String role;
  final String text;

  Map<String, dynamic> toJson() => {'role': role, 'text': text};
}

class Proposal {
  /// [ticked] defaults to every action; the service passes the real default
  /// (everything except destructive actions).
  Proposal({
    required this.id,
    required this.actions,
    required this.note,
    required this.weekStart,
    required this.labels,
    Set<int>? ticked,
    Map<int, Map<String, dynamic>>? edits,
  })  : ticked = ticked ?? {for (var i = 0; i < actions.length; i++) i},
        edits = edits ?? {};

  factory Proposal.fromJson(Map<String, dynamic> json) => Proposal(
        id: json['id'] as String,
        actions: (json['actions'] as List)
            .map((e) => AssistAction.fromJson(e as Map<String, dynamic>))
            .toList(),
        note: json['note'] as String,
        weekStart: json['weekStart'] as String,
        labels: Map<String, String>.from(json['labels'] as Map),
        ticked: Set<int>.from(json['ticked'] as List),
        edits: (json['edits'] as Map).map(
          (k, v) => MapEntry(
            int.parse(k as String),
            Map<String, dynamic>.from(v as Map),
          ),
        ),
      );

  final String id;
  final List<AssistAction> actions;
  final String note;
  final String weekStart;
  final Map<String, String> labels;
  Set<int> ticked;
  Map<int, Map<String, dynamic>> edits;

  Map<String, dynamic> toJson() => {
        'id': id,
        'actions': actions.map((e) => e.toJson()).toList(),
        'note': note,
        'weekStart': weekStart,
        'labels': labels,
        'ticked': ticked.toList()..sort(),
        'edits': edits.map((k, v) => MapEntry('$k', v)),
      };
}

class UndoRecord {
  UndoRecord({required this.type, required this.data});

  factory UndoRecord.fromJson(Map<String, dynamic> json) => UndoRecord(
        type: json['type'] as String,
        data: Map<String, dynamic>.from(json['data'] as Map),
      );

  final String type;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {'type': type, 'data': data};
}

class AppliedProposal {
  AppliedProposal({
    required this.id,
    required this.appliedAt,
    required this.actions,
    List<UndoRecord>? records,
    Map<String, String>? tempIds,
    this.status = AppliedStatus.applying,
    this.error,
  })  : records = records ?? [],
        tempIds = tempIds ?? {};

  factory AppliedProposal.fromJson(Map<String, dynamic> json) =>
      AppliedProposal(
        id: json['id'] as String,
        appliedAt: DateTime.parse(json['appliedAt'] as String),
        actions: (json['actions'] as List)
            .map((e) => AssistAction.fromJson(e as Map<String, dynamic>))
            .toList(),
        records: (json['records'] as List? ?? [])
            .map((e) => UndoRecord.fromJson(e as Map<String, dynamic>))
            .toList(),
        tempIds: Map<String, String>.from(json['tempIds'] as Map? ?? {}),
        status: _enum(AppliedStatus.values, json['status']),
        error: json['error'] as String?,
      );

  final String id;
  final DateTime appliedAt;

  /// Ticked and edited, in order.
  final List<AssistAction> actions;

  /// One per action done so far.
  final List<UndoRecord> records;
  final Map<String, String> tempIds;
  AppliedStatus status;
  String? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'appliedAt': appliedAt.toIso8601String(),
        'actions': actions.map((e) => e.toJson()).toList(),
        'records': records.map((e) => e.toJson()).toList(),
        'tempIds': tempIds,
        'status': status.name,
        'error': error,
      };
}

class AssistantState {
  AssistantState({
    this.enabled = true,
    this.consentedStage = AssistStage.none,
    List<ChatTurn>? thread,
    this.proposal,
    List<AppliedProposal>? applied,
  })  : thread = thread ?? [],
        applied = applied ?? [];

  factory AssistantState.fromJson(Map<String, dynamic> json) => AssistantState(
        enabled: json['enabled'] as bool? ?? true,
        consentedStage: json['consentedStage'] == null
            ? AssistStage.none
            : _enum(AssistStage.values, json['consentedStage']),
        thread: (json['thread'] as List? ?? [])
            .map((e) => ChatTurn.fromJson(e as Map<String, dynamic>))
            .toList(),
        proposal: json['proposal'] == null
            ? null
            : Proposal.fromJson(json['proposal'] as Map<String, dynamic>),
        applied: (json['applied'] as List? ?? [])
            .map((e) => AppliedProposal.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  bool enabled;
  AssistStage consentedStage;
  List<ChatTurn> thread;
  Proposal? proposal;
  List<AppliedProposal> applied;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'consentedStage': consentedStage.name,
        'thread': thread.map((e) => e.toJson()).toList(),
        'proposal': proposal?.toJson(),
        'applied': applied.map((e) => e.toJson()).toList(),
      };
}
