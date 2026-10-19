import 'dart:math';

import 'package:appflowy/core/config/kv.dart';
import 'package:appflowy/env/env.dart';
import 'package:appflowy/features/ai_organize/data/organize_api.dart';
import 'package:appflowy/features/ai_organize/data/organize_backend.dart';
import 'package:appflowy/features/ai_organize/data/organize_models.dart';
import 'package:appflowy/features/assistant/actions/board_actions.dart';
import 'package:appflowy/features/assistant/actions/calendar_actions.dart';
import 'package:appflowy/features/assistant/actions/database_actions.dart';
import 'package:appflowy/features/assistant/actions/page_content_actions.dart';
import 'package:appflowy/features/assistant/actions/page_workspace_actions.dart';
import 'package:appflowy/features/assistant/data/assist_api.dart';
import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/data/assistant_store.dart';
import 'package:appflowy/features/assistant/gateways/board_gateway.dart';
import 'package:appflowy/features/assistant/gateways/calendar_gateway.dart';
import 'package:appflowy/features/assistant/gateways/database_gateway.dart';
import 'package:appflowy/features/assistant/gateways/page_gateway.dart';
import 'package:appflowy/features/assistant/logic/action_engine.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy/features/assistant/logic/mentions.dart';
import 'package:appflowy/shared/af_user_profile_extension.dart';
import 'package:appflowy/startup/startup.dart';
import 'package:appflowy/user/application/user_service.dart';
import 'package:appflowy_backend/log.dart';
import 'package:appflowy_result/appflowy_result.dart';
import 'package:flutter/foundation.dart';
import 'package:nanoid/nanoid.dart';

/// Highest stage this build can act on.
const AssistStage kBuiltStage = AssistStage.workspace;

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
    required PageGateway pages,
    required DatabaseGateway databases,
    required Future<String?> Function() accessToken,
    DateTime Function()? now,
  })  : _store = store,
        _api = api,
        _engine = engine,
        _calendar = calendar,
        _boards = boards,
        _pages = pages,
        _databases = databases,
        _accessToken = accessToken,
        _now = now ?? DateTime.now;

  final AssistantStore _store;
  final AssistApi _api;
  final ActionEngine _engine;
  final CalendarGateway _calendar;
  final BoardGateway _boards;
  final PageGateway _pages;
  final DatabaseGateway _databases;
  final Future<String?> Function() _accessToken;
  final DateTime Function() _now;
  Future<AssistantState>? _state;
  final _busy = <String>{};

  static final _byUser = <String, AssistantService>{};

  /// Null when the assist URL is empty or the user has no auth token.
  /// Cached per user id.
  static Future<AssistantService?> current() async {
    final service = await _current();
    if (service == null) availability.value = false;
    return service;
  }

  /// Live "Ask InkNest is available" flag that entry points listen to.
  static final ValueNotifier<bool> availability = ValueNotifier(false);

  static Future<AssistantService?> _current() async {
    final url = assistUrlFrom(Env.inknestOrganizeUrl);
    if (url.isEmpty) return null;
    final profile =
        await UserBackendService.getCurrentUserProfile().toNullable();
    if (profile == null || profile.authToken == null) return null;
    final userId = profile.id.toString();
    return _byUser[userId] ??= () {
      final calendar = CalendarGateway();
      final boards = BoardGateway();
      final pages = PageGateway();
      final databases = DatabaseGateway();
      return AssistantService(
        store: AssistantStore(kv: getIt<KeyValueStorage>(), userId: userId),
        api: AssistApi(url: url),
        engine: ActionEngine([
          ...calendarHandlers(calendar),
          ...boardHandlers(boards),
          ...pageContentHandlers(pages),
          ...pageWorkspaceHandlers(pages),
          ...databaseHandlers(databases),
        ]),
        calendar: calendar,
        boards: boards,
        pages: pages,
        databases: databases,
        accessToken: const OrganizeBackend().accessToken,
      );
    }();
  }

  static Future<bool> isAvailable() async {
    final service = await current();
    final ok = service != null && (await service.state()).enabled;
    availability.value = ok;
    return ok;
  }

  /// Caches the load Future so concurrent first calls share one state.
  Future<AssistantState> state() => _state ??= _store.load();

  Future<void> setEnabled(bool enabled) async {
    final s = await state();
    s.enabled = enabled;
    await _store.save(s);
    availability.value = enabled;
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

  /// [pinnedIds] (header buttons) first, then boards, databases and pages
  /// named in [message]; each item once, as its most specific kind.
  Future<List<Mentionable>> mentionsFor(
    String message, {
    List<String> pinnedIds = const [],
  }) async {
    final boards = await _boards.boards();
    final boardIds = {for (final b in boards) b.id};
    final dbs = [
      for (final d in await _databases.databases())
        if (!boardIds.contains(d.id)) d,
    ];
    final taken = {...boardIds, for (final d in dbs) d.id};
    final items = [
      for (final b in boards)
        Mentionable(id: b.id, name: b.name, kind: 'board'),
      for (final d in dbs)
        Mentionable(id: d.id, name: d.name, kind: 'database'),
      for (final p in await _pages.tree())
        if (p.layout != 'space' && !taken.contains(p.id))
          Mentionable(id: p.id, name: p.name, kind: 'page'),
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
    final open = s.proposal;
    final boardIds = {for (final b in await _boards.boards()) b.id};
    // Mentioned boards, then those the open proposal touches (a `new:` id is
    // not a board yet, so it drops out here).
    final detailed = {
      ...mentionIds,
      for (final a in open?.actions ?? const <AssistAction>[])
        if (a.fields['board_id'] case final String id) id,
    }.where(boardIds.contains).take(3).toList();
    final cal = await calendarContext(_calendar, week);
    final board = await boardContext(_boards, detailed);
    // Pages (tree + mentioned text) only once consented to that stage.
    final page = stage.index >= AssistStage.pages.index
        ? await pageContext(_pages, mentionIds)
        : null;
    // Databases: mentioned ones, then those the open proposal touches.
    final db = stage.index >= AssistStage.workspace.index
        ? await databaseContext(_databases, [
            ...mentionIds,
            for (final a in open?.actions ?? const <AssistAction>[])
              if (a.fields['database_id'] case final String id) id,
          ])
        : null;
    final parts = [cal, board, if (page != null) page, if (db != null) db];
    final turns = s.thread.sublist(max(0, s.thread.length - kMaxTurns));
    final reply = await _post({
      'allowed_actions': _engine.typesUpTo(stage),
      'messages': [for (final t in turns) t.toJson()],
      'context': {
        'week_start': weekStart,
        'calendar': cal.json,
        'boards': board.json['boards'],
        ...?page?.json,
        ...?db?.json,
      },
      if (open != null) 'proposal': [for (final a in _chosen(open)) a.fields],
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
    // Only labels the kept actions can use (`<id>` or `<id>#…`), so a stored
    // proposal doesn't carry the whole context.
    final used = {for (final a in actions) ..._strings(a.fields)};
    final labels = {
      for (final p in parts)
        for (final e in p.labels.entries)
          if (used.contains(e.key.split('#').first)) e.key: e.value,
    };
    s.thread.add(ChatTurn(role: 'assistant', text: reply.note));
    // Applied (or replaced) while we waited: the reply revises a proposal
    // that is gone, so keep only its note.
    if (!identical(s.proposal, open)) {
      await _store.save(s);
      return null;
    }
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
  /// edits. Saved before the first action and after each. Throws StateError,
  /// recording nothing, when no proposal is open (a second tap finds it
  /// already taken), nothing is ticked, or a ticked action needs a `new:` id
  /// that only an unticked one creates.
  Future<AppliedProposal> apply() async {
    final s = await state();
    final open = s.proposal ?? (throw StateError('No open proposal'));
    final actions = _chosen(open);
    if (actions.isEmpty) throw StateError('Nothing ticked');
    final declared = {for (final a in actions) ...declaredTemps(a)};
    if (actions
        .expand((a) => _tempIds(a.fields))
        .any((t) => !declared.contains(t))) {
      throw StateError('A ticked change needs one that is not ticked');
    }
    final p = AppliedProposal(
      id: open.id,
      appliedAt: _now().toUtc(),
      actions: actions,
      labels: {...open.labels},
    );
    return _guard(p.id, () async {
      s.applied.add(p);
      if (s.applied.length > kMaxApplied) {
        s.applied.removeRange(0, s.applied.length - kMaxApplied);
      }
      s.proposal = null;
      await _store.save(s);
      await _engine.apply(p, onProgress: () => _store.save(s));
      await _store.save(s);
      return p;
    });
  }

  /// Continues a `partial` proposal from its first undone action, or an
  /// `applying` one whose run stopped before its first save (the guard rules
  /// out a live run); any other status is returned untouched.
  Future<AppliedProposal> retry(String appliedId) async {
    final s = await state();
    final p = s.applied.firstWhere((a) => a.id == appliedId);
    return _guard(p.id, () async {
      if (p.status != AppliedStatus.partial &&
          p.status != AppliedStatus.applying) {
        return p;
      }
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

  /// What the UI shows for [a].
  ActionPreview describe(AssistAction a, Map<String, String> labels) =>
      _engine.describe(a, labels);

  /// Closes the open proposal without applying it; the thread stays.
  Future<void> discard() async {
    final s = await state();
    s.proposal = null;
    await _store.save(s);
  }

  Future<void> clearConversation() async {
    final s = await state();
    s
      ..thread.clear()
      ..proposal = null;
    await _store.save(s);
  }

  /// The ticked actions, in order, with the user's edits to keys the
  /// preview marks editable (others are ignored); an edit to a key of the
  /// action's `cells` goes into a copy of `cells`. What apply runs and what
  /// a follow-up sends back.
  List<AssistAction> _chosen(Proposal p) => [
        for (final i in p.ticked.toList()..sort())
          if (p.actions[i] case final a) _edited(a, p.edits[i], p.labels),
      ];

  AssistAction _edited(
    AssistAction a,
    Map<String, dynamic>? edits,
    Map<String, String> labels,
  ) {
    final editable = _engine.describe(a, labels).editable;
    final fields = {...a.fields};
    final cells = fields['cells'] is Map ? {...fields['cells'] as Map} : null;
    for (final e in {...?edits}.entries) {
      if (!editable.contains(e.key)) continue;
      if (cells != null && cells.containsKey(e.key)) {
        cells[e.key] = e.value;
      } else {
        fields[e.key] = e.value;
      }
    }
    if (cells != null) fields['cells'] = cells;
    return AssistAction(type: a.type, fields: fields);
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

/// Every `new:` id anywhere in [v], declared or referenced.
Iterable<String> _tempIds(Object? v) =>
    _strings(v).where((s) => s.startsWith('new:'));

/// Every string in [v], map keys included (row cells use field ids as keys).
Iterable<String> _strings(Object? v) sync* {
  if (v is String) yield v;
  if (v is Map) {
    for (final e in v.entries) {
      yield* _strings(e.key);
      yield* _strings(e.value);
    }
  }
  if (v is List) {
    for (final x in v) {
      yield* _strings(x);
    }
  }
}
