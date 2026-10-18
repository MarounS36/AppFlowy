enum ProposalState {
  processing,
  needsReview,
  applied,
  rejected,
  partiallyApplied,
  failed,
  stale,
}

enum OrganizeField { title, folder }

enum OrganizeErrorKind {
  unauthorized,
  notInvited,
  userLimit,
  globalLimit,
  tooLarge,
  noteMissing,
  failed,
}

T _enum<T extends Enum>(List<T> values, Object? name) =>
    values.firstWhere((e) => e.name == name);

T? _enumOrNull<T extends Enum>(List<T> values, Object? name) =>
    name == null ? null : _enum(values, name);

class NoteSnapshot {
  const NoteSnapshot({
    required this.title,
    required this.parentId,
    this.prevSiblingId,
    required this.bodyHash,
  });

  factory NoteSnapshot.fromJson(Map<String, dynamic> json) => NoteSnapshot(
        title: json['title'] as String,
        parentId: json['parentId'] as String,
        prevSiblingId: json['prevSiblingId'] as String?,
        bodyHash: json['bodyHash'] as String,
      );

  final String title;
  final String parentId;
  final String? prevSiblingId;
  final String bodyHash;

  Map<String, dynamic> toJson() => {
        'title': title,
        'parentId': parentId,
        'prevSiblingId': prevSiblingId,
        'bodyHash': bodyHash,
      };
}

class OrganizeProposal {
  OrganizeProposal({
    required this.id,
    required this.noteId,
    required this.createdAt,
    required this.snapshot,
    this.proposedTitle,
    this.proposedFolderId,
    this.proposedFolderPath,
    required this.currentFolderPath,
    required this.reason,
    required this.state,
    this.error,
  });

  factory OrganizeProposal.fromJson(Map<String, dynamic> json) =>
      OrganizeProposal(
        id: json['id'] as String,
        noteId: json['noteId'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        snapshot:
            NoteSnapshot.fromJson(json['snapshot'] as Map<String, dynamic>),
        proposedTitle: json['proposedTitle'] as String?,
        proposedFolderId: json['proposedFolderId'] as String?,
        proposedFolderPath: json['proposedFolderPath'] as String?,
        currentFolderPath: json['currentFolderPath'] as String,
        reason: json['reason'] as String,
        state: _enum(ProposalState.values, json['state']),
        error: _enumOrNull(OrganizeErrorKind.values, json['error']),
      );

  final String id;
  final String noteId;
  final DateTime createdAt;
  final NoteSnapshot snapshot;
  final String? proposedTitle;
  final String? proposedFolderId;
  final String? proposedFolderPath;
  final String currentFolderPath;
  final String reason;
  ProposalState state;
  OrganizeErrorKind? error;

  Map<String, dynamic> toJson() => {
        'id': id,
        'noteId': noteId,
        'createdAt': createdAt.toIso8601String(),
        'snapshot': snapshot.toJson(),
        'proposedTitle': proposedTitle,
        'proposedFolderId': proposedFolderId,
        'proposedFolderPath': proposedFolderPath,
        'currentFolderPath': currentFolderPath,
        'reason': reason,
        'state': state.name,
        'error': error?.name,
      };
}

/// Per-field accepted values; null means the field was not accepted.
class OrganizeDecision {
  const OrganizeDecision({this.title, this.folderId});

  factory OrganizeDecision.fromJson(Map<String, dynamic> json) =>
      OrganizeDecision(
        title: json['title'] as String?,
        folderId: json['folderId'] as String?,
      );

  final String? title;
  final String? folderId;

  Map<String, dynamic> toJson() => {'title': title, 'folderId': folderId};
}

class HistoryEntry {
  HistoryEntry({
    required this.proposalId,
    required this.noteId,
    required this.field,
    required this.appliedAt,
    required this.before,
    required this.after,
    this.beforePrevSiblingId,
    required this.beforeLabel,
    required this.afterLabel,
    this.undone = false,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        proposalId: json['proposalId'] as String,
        noteId: json['noteId'] as String,
        field: _enum(OrganizeField.values, json['field']),
        appliedAt: DateTime.parse(json['appliedAt'] as String),
        before: json['before'] as String,
        after: json['after'] as String,
        beforePrevSiblingId: json['beforePrevSiblingId'] as String?,
        beforeLabel: json['beforeLabel'] as String,
        afterLabel: json['afterLabel'] as String,
        undone: json['undone'] as bool? ?? false,
      );

  final String proposalId;
  final String noteId;
  final OrganizeField field;
  final DateTime appliedAt;

  /// Titles for [OrganizeField.title], parent view ids for [OrganizeField.folder].
  final String before;
  final String after;
  final String? beforePrevSiblingId;

  /// Display text (titles or folder paths).
  final String beforeLabel;
  final String afterLabel;
  bool undone;

  String get key => '$proposalId:${field.name}';

  Map<String, dynamic> toJson() => {
        'proposalId': proposalId,
        'noteId': noteId,
        'field': field.name,
        'appliedAt': appliedAt.toIso8601String(),
        'before': before,
        'after': after,
        'beforePrevSiblingId': beforePrevSiblingId,
        'beforeLabel': beforeLabel,
        'afterLabel': afterLabel,
        'undone': undone,
      };
}

class Rejections {
  Rejections({
    required this.bodyHash,
    List<String>? titles,
    List<String>? folderIds,
  })  : titles = titles ?? [],
        folderIds = folderIds ?? [];

  factory Rejections.fromJson(Map<String, dynamic> json) => Rejections(
        bodyHash: json['bodyHash'] as String,
        titles: List<String>.from(json['titles'] as List),
        folderIds: List<String>.from(json['folderIds'] as List),
      );

  final String bodyHash;
  final List<String> titles;
  final List<String> folderIds;

  Map<String, dynamic> toJson() => {
        'bodyHash': bodyHash,
        'titles': titles,
        'folderIds': folderIds,
      };
}

class OrganizeState {
  OrganizeState({
    this.enabled = true,
    this.consented = false,
    List<OrganizeProposal>? proposals,
    List<HistoryEntry>? history,
    Map<String, Rejections>? rejections,
  })  : proposals = proposals ?? [],
        history = history ?? [],
        rejections = rejections ?? {};

  factory OrganizeState.fromJson(Map<String, dynamic> json) => OrganizeState(
        enabled: json['enabled'] as bool? ?? true,
        consented: json['consented'] as bool? ?? false,
        proposals: (json['proposals'] as List? ?? [])
            .map((e) => OrganizeProposal.fromJson(e as Map<String, dynamic>))
            .toList(),
        history: (json['history'] as List? ?? [])
            .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        rejections: (json['rejections'] as Map<String, dynamic>? ?? {}).map(
          (k, v) => MapEntry(k, Rejections.fromJson(v as Map<String, dynamic>)),
        ),
      );

  bool enabled;
  bool consented;
  List<OrganizeProposal> proposals;
  List<HistoryEntry> history;
  Map<String, Rejections> rejections;

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'consented': consented,
        'proposals': proposals.map((e) => e.toJson()).toList(),
        'history': history.map((e) => e.toJson()).toList(),
        'rejections': rejections.map((k, v) => MapEntry(k, v.toJson())),
      };
}
