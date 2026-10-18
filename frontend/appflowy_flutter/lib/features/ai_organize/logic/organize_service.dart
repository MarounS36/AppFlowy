import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/env/env.dart';
import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_backend.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/ai_organize/data/organize_store.dart';
import 'package:appflowy/features/ai_organize/logic/folder_candidates.dart';
import 'package:appflowy/features/ai_organize/logic/organize_rules.dart';
import 'package:appflowy/shared/af_user_profile_extension.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/user/application/user_service.dart';
import 'package:appflowy/workspace/application/view/view_ext.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_backend/protobuf/flowy-folder/view.pb.dart';
import 'package:appflowy_result/appflowy_result.dart';
import 'package:nanoid/nanoid.dart';

enum UndoResult { undone, conflict, alreadyUndone }

const _open = {
  ProposalState.processing,
  ProposalState.needsReview,
  ProposalState.stale,
  ProposalState.failed,
};

/// Request, apply, reject and undo AI Organize proposals.
///
/// State is loaded once and shared: every mutation happens synchronously on
/// that one object (no await between check and change), then it is saved.
/// That is what makes concurrent [apply] calls apply once.
class OrganizeService {
  OrganizeService({
    required OrganizeBackend backend,
    required OrganizeStore store,
    required OrganizeApi api,
  })  : _backend = backend,
        _store = store,
        _api = api;

  final OrganizeBackend _backend;
  final OrganizeStore _store;
  final OrganizeApi _api;
  Future<OrganizeState>? _state;

  /// Proposals whose apply is in flight; a re-run must not drop them.
  final _applying = <String>{};

  static final _byUser = <String, OrganizeService>{};

  /// Null when Env.inknestOrganizeUrl is empty or the user has no auth token.
  /// Cached per user id.
  static Future<OrganizeService?> current() async {
    if (Env.inknestOrganizeUrl.isEmpty) return null;
    final profile =
        await UserBackendService.getCurrentUserProfile().toNullable();
    if (profile == null || profile.authToken == null) return null;
    final userId = profile.id.toString();
    return _byUser[userId] ??= OrganizeService(
      backend: const OrganizeBackend(),
      store: OrganizeStore(kv: getIt<KeyValueStorage>(), userId: userId),
      api: OrganizeApi(url: Env.inknestOrganizeUrl),
    );
  }

  static Future<bool> isAvailable() async {
    final service = await current();
    return service != null && (await service.state()).enabled;
  }

  /// Caches the load Future, not its result, so concurrent first calls
  /// share one in-memory state.
  Future<OrganizeState> state() => _state ??= _store.load();

  Future<void> setEnabled(bool enabled) async {
    final s = await state();
    s.enabled = enabled;
    await _store.save(s);
  }

  Future<void> setConsented() async {
    final s = await state();
    s.consented = true;
    await _store.save(s);
  }

  Future<List<FolderCandidate>> candidatesFor(String noteId) async =>
      _editableCandidates(await _backend.allViews(), noteId);

  /// Replaces any open (processing/needsReview/stale/failed) proposal for the
  /// note. Returns null when the AI has nothing to suggest (nothing stored).
  /// AI failures come back as a `failed` proposal; a missing note throws
  /// OrganizeApiException(noteMissing); switched off, not consented or other
  /// read errors throw OrganizeApiException(failed). Never writes to the note.
  Future<OrganizeProposal?> request(String noteId) async {
    try {
      return await _request(noteId);
    } on OrganizeApiException {
      rethrow;
    } catch (e) {
      Log.error('AI Organize: request failed: $e');
      throw const OrganizeApiException(OrganizeErrorKind.failed);
    }
  }

  Future<OrganizeProposal?> _request(String noteId) async {
    final state = await this.state();
    // Switch off or no consent: send nothing (every Retry/Re-run comes here).
    if (!state.enabled || !state.consented) {
      throw const OrganizeApiException(OrganizeErrorKind.failed);
    }
    final note = await _backend.readNote(noteId);
    if (note == null) {
      throw const OrganizeApiException(OrganizeErrorKind.noteMissing);
    }
    final snapshot = note.snapshot;
    final views = await _backend.allViews();
    final byId = {for (final v in views) v.id: v};
    final candidates = await _editableCandidates(views, noteId);

    if (state.rejections[noteId]?.bodyHash != snapshot.bodyHash) {
      state.rejections.remove(noteId);
    }
    final exclude = state.rejections[noteId];
    final body = {
      'note': {
        'id': noteId,
        'title': snapshot.title,
        'text': note.text.length > kMaxNoteChars
            ? note.text.substring(0, kMaxNoteChars)
            : note.text,
        'current_parent_id': snapshot.parentId,
      },
      'folders': [for (final c in candidates) c.toJson()],
      'exclude': {
        'titles': [...?exclude?.titles],
        'folder_ids': [...?exclude?.folderIds],
      },
    };

    final id = nanoid();
    final createdAt = DateTime.now().toUtc();
    final currentFolderPath = viewPath(snapshot.parentId, byId) ?? '';
    final pending = OrganizeProposal(
      id: id,
      noteId: noteId,
      createdAt: createdAt,
      snapshot: snapshot,
      currentFolderPath: currentFolderPath,
      reason: '',
      state: ProposalState.processing,
    );
    _replaceOpen(state, noteId, pending);

    OrganizeProposal? result = pending;
    try {
      await _store.save(state);
      final s = await _organize(body);
      // The server validates too; never let an id we didn't offer reach move.
      final folderId =
          candidates.any((c) => c.id == s.folderId) ? s.folderId : null;
      result = s.title == null && folderId == null
          ? null
          : OrganizeProposal(
              id: id,
              noteId: noteId,
              createdAt: createdAt,
              snapshot: snapshot,
              proposedTitle: s.title,
              proposedFolderId: folderId,
              proposedFolderPath:
                  folderId == null ? null : viewPath(folderId, byId) ?? '',
              currentFolderPath: currentFolderPath,
              reason: s.reason,
              state: ProposalState.needsReview,
            );
    } catch (e) {
      Log.error('AI Organize: suggestion failed: $e');
      pending
        ..state = ProposalState.failed
        ..error = e is OrganizeApiException ? e.kind : OrganizeErrorKind.failed;
    }
    _replaceOpen(state, noteId, result);
    await _store.save(state);
    return result;
  }

  /// On `unauthorized`, re-reads the token once and retries once.
  Future<OrganizeSuggestion> _organize(Map<String, dynamic> body) async {
    Future<OrganizeSuggestion> once() async {
      final token = await _backend.accessToken();
      if (token == null) {
        throw const OrganizeApiException(OrganizeErrorKind.unauthorized);
      }
      return _api.organize(token: token, body: body);
    }

    try {
      return await once();
    } on OrganizeApiException catch (e) {
      if (e.kind != OrganizeErrorKind.unauthorized) rethrow;
      return once();
    }
  }

  /// Applies the accepted (non-null) fields of [decision]. Runs only from
  /// `needsReview`, or from `stale` with [force] ("Apply anyway", which then
  /// skips the stale check); otherwise returns the current state untouched.
  /// Throws StateError for an unknown id.
  Future<ProposalState> apply(
    String proposalId,
    OrganizeDecision decision, {
    bool force = false,
  }) async {
    final state = await this.state();
    final p = state.proposals.firstWhere((p) => p.id == proposalId);
    final applyAnyway = force && p.state == ProposalState.stale;
    if (p.state != ProposalState.needsReview && !applyAnyway) return p.state;
    p
      ..state = ProposalState.processing
      ..error = null;
    _applying.add(p.id);

    var performed = false;
    Future<void> record(HistoryEntry entry) async {
      state.history.add(entry);
      performed = true;
      await _store.save(state);
    }

    try {
      await _store.save(state);
      final note = await _backend.readNote(p.noteId);
      if (note == null) {
        p
          ..state = ProposalState.failed
          ..error = OrganizeErrorKind.noteMissing;
      } else if (!applyAnyway && isStale(p.snapshot, note.snapshot)) {
        p.state = ProposalState.stale;
      } else {
        final now = note.snapshot;
        _addRejections(
          state,
          p.noteId,
          now.bodyHash,
          title: decision.title == null ? p.proposedTitle : null,
          folderId: decision.folderId == null ? p.proposedFolderId : null,
        );

        final title = decision.title;
        if (title != null && title != now.title) {
          await _backend.rename(p.noteId, title);
          await record(
            _entry(p, OrganizeField.title, now.title, title, now.title, title),
          );
        }

        final folderId = decision.folderId;
        if (folderId != null && folderId != now.parentId) {
          // Moving into a trashed, locked or descendant view is accepted by
          // the backend and can hide the note, so re-check right before.
          final views = await _backend.allViews();
          final stillFolder = buildFolderCandidates(
            views: views,
            noteId: p.noteId,
          ).any((c) => c.id == folderId);
          if (!stillFolder || !await _backend.canEdit(folderId)) {
            throw StateError('AI Organize: destination is not a folder');
          }
          await _backend.move(p.noteId, parentId: folderId);
          final byId = {for (final v in views) v.id: v};
          await record(
            _entry(
              p,
              OrganizeField.folder,
              now.parentId,
              folderId,
              viewPath(now.parentId, byId) ?? '',
              viewPath(folderId, byId) ?? '',
              beforePrevSiblingId: now.prevSiblingId,
            ),
          );
        }

        // An accepted field counts as applied once the note holds its value,
        // whether we just wrote it or it was already there.
        p.state = finalState(p, {
          if (decision.title != null) OrganizeField.title,
          if (decision.folderId != null) OrganizeField.folder,
        });
      }
    } catch (e) {
      Log.error('AI Organize: apply failed: $e');
      p
        ..state =
            performed ? ProposalState.partiallyApplied : ProposalState.failed
        ..error = OrganizeErrorKind.failed;
    } finally {
      _applying.remove(p.id);
    }
    await _store.save(state);
    return p.state;
  }

  /// Only from needsReview, stale or failed; otherwise does nothing.
  /// Throws StateError for an unknown id.
  Future<void> reject(String proposalId) async {
    final state = await this.state();
    final p = state.proposals.firstWhere((p) => p.id == proposalId);
    const rejectable = {
      ProposalState.needsReview,
      ProposalState.stale,
      ProposalState.failed,
    };
    if (!rejectable.contains(p.state)) return;
    _addRejections(
      state,
      p.noteId,
      p.snapshot.bodyHash,
      title: p.proposedTitle,
      folderId: p.proposedFolderId,
    );
    p.state = ProposalState.rejected;
    await _store.save(state);
  }

  /// Reverts one history entry if the note still has the value we set.
  /// Throws StateError for an unknown key, FlowyError if the write fails
  /// (the entry then stays not undone).
  Future<UndoResult> undo(String historyKey) async {
    final state = await this.state();
    final entry = state.history.firstWhere((h) => h.key == historyKey);
    if (entry.undone) return UndoResult.alreadyUndone;

    // Only title and parent matter here, so don't read the body.
    final view = await _backend.view(entry.noteId);
    if (view == null) return UndoResult.conflict;
    final now = NoteSnapshot(
      title: view.name,
      parentId: view.parentViewId,
      bodyHash: '',
    );
    switch (entry.field) {
      case OrganizeField.title:
        if (!canUndo(entry, now, beforeParentExists: true)) {
          return UndoResult.conflict;
        }
        await _backend.rename(entry.noteId, entry.before);
      case OrganizeField.folder:
        final parentOk = await _canHost(entry.before, entry.noteId);
        if (!canUndo(entry, now, beforeParentExists: parentOk)) {
          return UndoResult.conflict;
        }
        final prev = entry.beforePrevSiblingId;
        final keepPrev = prev != null &&
            (await _backend.view(prev))?.parentViewId == entry.before;
        await _backend.move(
          entry.noteId,
          parentId: entry.before,
          prevViewId: keepPrev ? prev : null,
        );
    }
    entry.undone = true;
    await _store.save(state);
    return UndoResult.undone;
  }

  void _replaceOpen(OrganizeState s, String noteId, OrganizeProposal? p) {
    s.proposals.removeWhere(
      (x) =>
          x.noteId == noteId &&
          _open.contains(x.state) &&
          !_applying.contains(x.id),
    );
    if (p != null) s.proposals.add(p);
  }

  Future<List<FolderCandidate>> _editableCandidates(
    List<ViewPB> views,
    String noteId,
  ) async {
    final all = buildFolderCandidates(views: views, noteId: noteId);
    final editable = await Future.wait(all.map((c) => _backend.canEdit(c.id)));
    return [
      for (var i = 0; i < all.length; i++)
        if (editable[i]) all[i],
    ].take(kMaxFolders).toList();
  }

  /// [parentId] exists and is not [noteId] or inside it (moving a view under
  /// its own descendant would cut both out of the tree).
  Future<bool> _canHost(String parentId, String noteId) async {
    final seen = <String>{};
    var v = await _backend.view(parentId);
    if (v == null) return false;
    while (v != null && seen.add(v.id)) {
      if (v.id == noteId) return false;
      v = v.isSpace ? null : await _backend.view(v.parentViewId);
    }
    return true;
  }
}

/// Rejections are kept per note for one body hash; a new hash starts over.
void _addRejections(
  OrganizeState s,
  String noteId,
  String hash, {
  String? title,
  String? folderId,
}) {
  if (title == null && folderId == null) return;
  var r = s.rejections[noteId];
  if (r == null || r.bodyHash != hash) {
    r = s.rejections[noteId] = Rejections(bodyHash: hash);
  }
  if (title != null && !r.titles.contains(title)) r.titles.add(title);
  if (folderId != null && !r.folderIds.contains(folderId)) {
    r.folderIds.add(folderId);
  }
}

HistoryEntry _entry(
  OrganizeProposal p,
  OrganizeField field,
  String before,
  String after,
  String beforeLabel,
  String afterLabel, {
  String? beforePrevSiblingId,
}) =>
    HistoryEntry(
      proposalId: p.id,
      noteId: p.noteId,
      field: field,
      appliedAt: DateTime.now().toUtc(),
      before: before,
      after: after,
      beforePrevSiblingId: beforePrevSiblingId,
      beforeLabel: beforeLabel,
      afterLabel: afterLabel,
    );
