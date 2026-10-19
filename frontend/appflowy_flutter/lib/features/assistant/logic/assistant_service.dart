import 'dart:math';

import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/env/env.dart';
import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_backend.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/actions/board_actions.dart';
import 'package:appflowy/features/assistant/actions/calendar_actions.dart';
import 'package:appflowy/features/assistant/data/assist_api.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/data/assistant_store.dart';
import 'package:appflowy/features/assistant/gateways/board_gateway.dart';
import 'package:appflowy/features/assistant/gateways/calendar_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_engine.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy/features/assistant/logic/mentions.dart';
import 'package:appflowy/shared/af_user_profile_extension.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/user/application/user_service.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_result/appflowy_result.dart';
import 'package:nanoid/nanoid.dart';

/// Highest stage this build can act on. Task 14 → pages, Task 16 → workspace.
const AssistStage kBuiltStage = AssistStage.schedule;

const _maxTurns = 10;

/// Sends "Ask InkNest" messages, keeps the proposal, applies and undoes it.
///
/// Like OrganizeService, state is loaded once and shared, and every
/// check-then-change happens with no await in between. [_busy] keeps one
/// apply/retry/undo per proposal at a time, as the engine requires.
class AssistantService {
  AssistantService({
    required AssistantStore store,
    required AssistApi api,
    required ActionEngine engine,
    required CalendarGateway calendar,
    required BoardGateway boards,
    required Future<String?> Function() accessToken,
    DateTime Function()? now,
  })  : _store = store,
        _api = api,
        _engine = engine,
        _calendar = calendar,
        _boards = boards,
        _accessToken = accessToken,
        _now = now ?? DateTime.now;

  final AssistantStore _store;
  final AssistApi _api;
  final ActionEngine _engine;
  final CalendarGateway _calendar;
  final BoardGateway _boards;
  final Future<String?> Function() _accessToken;
  final DateTime Function() _now;
  Future<AssistantState>? _state;
  final _busy = <String>{};

  static final _byUser = <String, AssistantService>{};

  /// Null when the assist URL is empty or the user has no auth token.
  /// Cached per user id.
  static Future<AssistantService?> current() async {
    final url = assistUrlFrom(Env.inknestOrganizeUrl);
    if (url.isEmpty) return null;
    final profile =
        await UserBackendService.getCurrentUserProfile().toNullable();
    if (profile == null || profile.authToken == null) return null;
    final userId = profile.id.toString();
    return _byUser[userId] ??= () {
      final calendar = CalendarGateway();
      final boards = BoardGateway();
      return AssistantService(
        store: AssistantStore(kv: getIt<KeyValueStorage>(), userId: userId),
        api: AssistApi(url: url),
        engine: ActionEngine([
          ...calendarHandlers(calendar),
          ...boardHandlers(boards),
        ]),
        calendar: calendar,
        boards: boards,
        accessToken: const OrganizeBackend().accessToken,
      );
    }();
  }

  static Future<bool> isAvailable() async {
    final service = await current();
    return service != null && (await service.state()).enabled;
  }

  /// Caches the load Future so concurrent first calls share one state.
  Future<AssistantState> state() => _state ??= _store.load();

  Future<void> setEnabled(bool enabled) async {
    final s = await state();
    s.enabled = enabled;
    await _store.save(s);
  }

  Future<void> setConsentedStage(AssistStage stage) async {
    final s = await state();
    s.consentedStage = stage;
    await _store.save(s);
  }

  /// The lower of what the user consented to and what this build supports.
  Future<AssistStage> activeStage() async {
    final consented = (await state()).consentedStage;
    return consented.index < kBuiltStage.index ? consented : kBuiltStage;
  }

  /// [pinnedIds] (header buttons) first, then boards named in [message].
  Future<List<Mentionable>> mentionsFor(
    String message, {
    List<String> pinnedIds = const [],
  }) async {
    final items = [
      for (final b in await _boards.boards())
        Mentionable(id: b.id, name: b.name, kind: 'board'),
    ];
    final byId = {for (final m in items) m.id: m};
    final seen = <String>{};
    return [
      for (final id in pinnedIds)
        if (byId[id] case final m?) m,
      ...findMentions(message, items),
    ].where((m) => seen.add(m.id)).toList();
  }

  /// Sends [message] with the context it needs and stores the reply. Returns
  /// null (and closes any open proposal) when the reply has no valid action;
  /// the note is in the thread either way. Switched off or not consented:
  /// sends nothing and throws OrganizeApiException(failed); other failures
  /// throw OrganizeApiException and leave the thread as it was, so Retry
  /// doesn't repeat the message.
  Future<Proposal?> send(
    String message, {
    required List<String> mentionIds,
  }) async {
    final s = await state();
    final stage = await activeStage();
    if (!s.enabled || stage == AssistStage.none) {
      throw const OrganizeApiException(OrganizeErrorKind.failed);
    }
    final turn = ChatTurn(role: 'user', text: message);
    s.thread.add(turn);
    try {
      return await _send(s, message, mentionIds, stage);
    } catch (e) {
      s.thread.remove(turn);
      if (e is OrganizeApiException) rethrow;
      Log.error('Assistant: send failed: $e');
      throw const OrganizeApiException(OrganizeErrorKind.failed);
    }
  }

  Future<Proposal?> _send(
    AssistantState s,
    String message,
    List<String> mentionIds,
    AssistStage stage,
  ) async {
    final week = targetWeekStart(_now(), message);
    final weekStart = week.toIso8601String().substring(0, 10);
    final boardIds = {for (final b in await _boards.boards()) b.id};
    final cal = await calendarContext(_calendar, week);
    final board = await boardContext(
      _boards,
      mentionIds.where(boardIds.contains).toList(),
    );
    final parts = [cal, board];
    final open = s.proposal;
    final turns = s.thread.sublist(max(0, s.thread.length - _maxTurns));
    final reply = await _post({
      'allowed_actions': _engine.typesUpTo(stage),
      'messages': [for (final t in turns) t.toJson()],
      'context': {
        'week_start': weekStart,
        'calendar': cal.json,
        'boards': board.json['boards'],
      },
      if (open != null) 'proposal': [for (final a in open.actions) a.fields],
    });

    // The server validates too; never let an action we can't check through.
    final ids = {for (final p in parts) ...p.ids};
    final actions = _engine.filterValid(
      reply.actions,
      scope: ValidationScope(
        knownIds: ids,
        weekStart: week,
        readOnlyIds: {for (final p in parts) ...p.readOnlyIds},
        items: {for (final p in parts) ...p.items},
      ),
      stage: stage,
    );
    final labels = {for (final p in parts) ...p.labels};
    final proposal = actions.isEmpty
        ? null
        : Proposal(
            id: nanoid(),
            actions: actions,
            note: reply.note,
            weekStart: weekStart,
            labels: labels,
            ticked: {
              for (var i = 0; i < actions.length; i++)
                if (!_engine.describe(actions[i], labels).destructive) i,
            },
          );
    s.thread.add(ChatTurn(role: 'assistant', text: reply.note));
    s.proposal = proposal;
    await _store.save(s);
    return proposal;
  }

  /// On `unauthorized`, re-reads the token once and retries once.
  Future<AssistReply> _post(Map<String, dynamic> body) async {
    Future<AssistReply> once() async {
      final token = await _accessToken();
      if (token == null) {
        throw const OrganizeApiException(OrganizeErrorKind.unauthorized);
      }
      return _api.send(token: token, body: body);
    }

    try {
      return await once();
    } on OrganizeApiException catch (e) {
      if (e.kind != OrganizeErrorKind.unauthorized) rethrow;
      return once();
    }
  }

  /// Applies the open proposal's ticked actions, in order, with the user's
  /// edits. Saved before the first action and after each. Throws StateError
  /// when no proposal is open (a second tap finds it already taken).
  Future<AppliedProposal> apply() async {
    final s = await state();
    final open = s.proposal ?? (throw StateError('No open proposal'));
    final p = AppliedProposal(
      id: open.id,
      appliedAt: _now().toUtc(),
      actions: [
        for (final i in open.ticked.toList()..sort())
          AssistAction(
            type: open.actions[i].type,
            fields: {...open.actions[i].fields, ...?open.edits[i]},
          ),
      ],
    );
    return _guard(p.id, () async {
      s.applied.add(p);
      s.proposal = null;
      await _store.save(s);
      await _engine.apply(p, onProgress: () => _store.save(s));
      await _store.save(s);
      return p;
    });
  }

  /// Continues a `partial` proposal from its first undone action; any other
  /// status is returned untouched.
  Future<AppliedProposal> retry(String appliedId) async {
    final s = await state();
    final p = s.applied.firstWhere((a) => a.id == appliedId);
    return _guard(p.id, () async {
      if (p.status != AppliedStatus.partial) return p;
      await _engine.apply(p, onProgress: () => _store.save(s));
      await _store.save(s);
      return p;
    });
  }

  /// Saved afterwards: undo writes into records (e.g. a restored id) so a
  /// repeat is idempotent.
  Future<UndoReport> undo(String appliedId) async {
    final s = await state();
    final p = s.applied.firstWhere((a) => a.id == appliedId);
    return _guard(p.id, () async {
      final report = await _engine.undo(p);
      await _store.save(s);
      return report;
    });
  }

  Future<void> clearConversation() async {
    final s = await state();
    s
      ..thread.clear()
      ..proposal = null;
    await _store.save(s);
  }

  /// Claims [id] synchronously; a concurrent apply/retry/undo of the same
  /// proposal throws StateError instead of running the engine again.
  Future<T> _guard<T>(String id, Future<T> Function() run) async {
    if (!_busy.add(id)) throw StateError('Assistant: $id is busy');
    try {
      return await run();
    } finally {
      _busy.remove(id);
    }
  }
}
