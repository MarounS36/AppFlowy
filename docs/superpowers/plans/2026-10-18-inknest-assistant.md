# InkNest Assistant Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An "Ask InkNest" assistant on desktop and mobile that turns plain-language requests into previewed, approve-first, undoable actions — schedule + boards (v1), pages with content (v2), the rest of the workspace (v3).

**Architecture:** A new Supabase Edge Function `assist` (sharing the `organize` function's auth/limit/AI pipeline) returns a list of typed actions validated against a catalogue. The Flutter app builds a scoped context, shows a preview, and runs ticked actions through an action registry (one handler per action type, each with apply + undo) on top of thin gateways over existing AppFlowy Dart services. No Rust changes.

**Tech Stack:** Deno + supabase-js (server); Flutter 3.27.4, `http`, `mocktail`, existing AppFlowy database/folder/document services (app).

**Spec:** `docs/superpowers/specs/2026-10-18-inknest-assistant-design.md` — read it before any task. Calendar API notes: `docs/superpowers/specs/2026-10-18-inknest-plan-my-week-design.md` §App.

## Global Constraints

- Flutter **3.27.4**: prefix Flutter/Dart commands with `PATH="$HOME/Documents/flutter-3.27.4/bin:$PATH"`, run from `frontend/appflowy_flutter`, pipe `flutter test` output through `| tail -3`. Never the global Flutter.
- No changes under `frontend/rust-lib`.
- Approve-first: nothing changes before **Apply selected**; only ticked actions run.
- Server: same auth, allowlist, shared daily usage counter, error codes and no-content logging as `organize`. Body cap **524288** bytes. Error body `{"error": "<code>"}`.
- Proposal caps: ≤ **80** actions; names/titles one line, non-empty, ≤ **120** chars; calendar dates inside `week_start … week_start+6`; `start < end` (`HH:MM`, 24 h) unless `all_day`.
- Context caps: **200** cards per board, **3** detailed boards, **500** pages in the tree, **8000** chars of text per page × **3** pages, **200** rows per database, last **10** conversation turns.
- Mention rule: whole name, case-insensitive, whole-word, names of **3+** characters; header-button pre-mentions always count; user can remove chips before sending.
- Writable cell types (v3): text, number, date, select, multi-select, checkbox. All others are read-only and never written; `row.remove` only for rows whose non-empty cells are all writable.
- Deletes go to Trash only (pages/boards/databases); never permanent.
- App timeout **150** s; working text "Working… this can take a minute".
- Store per user per device; keep the newest **20** applied proposals.
- Consent per stage (1 schedule+boards, 2 pages, 3 workspace); declining a later stage keeps the assistant at the highest consented stage.
- Strings via `LocaleKeys.assistant_*` in `frontend/resources/translations/en-US.json`.
- New Dart code in `frontend/appflowy_flutter/lib/features/assistant/`; tests in `test/unit_test/assistant/` and `test/widget_test/assistant/`.
- Every **Commit** step: `git add` exactly the task's Files (+ `pubspec.lock` if changed); never `frontend/appflowy_flutter/macos/Podfile.lock`, `.../project.pbxproj`, any `.env`. Messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Action references a temp id defined later or never** (`new:3` used before `board.create` with `temp_id: new:3`) → dropped by server and app; later valid actions kept. Test: Task 2, Task 7.
2. **App killed mid-apply** → on reload the applied proposal shows "Applied N of M" with Retry; Retry resumes using the stored temp-id map and never re-creates earlier items. Test: Task 7.
3. **Item deleted or renamed between proposal and apply** (board gone, entry gone) → that action fails, apply stops, report "Applied N of M"; earlier actions stay undoable. Test: Task 7.
4. **User edits an applied item by hand, then Undo** → that item is skipped and reported, others revert. Tests: Task 8 (entry), Task 9 (card), Task 14 (appended text).
5. **Two items share a mentioned name** → both appear as chips; the user can remove one; server prompt tells the model to ask instead of guessing. Test: Task 6.

---

## Part A — Server (`inknest/supabase/functions`)

### Task 1: Shared AI pipeline

**Files:**
- Create: `inknest/supabase/functions/_shared/pipeline.ts`, `inknest/supabase/functions/_shared/deps.ts` (moved from `organize/deps.ts`), `inknest/supabase/functions/_shared/deps_test.ts` (moved from `organize/deps_test.ts`)
- Modify: `organize/core.ts` (move `ChatMessage`, `parseModelOutput` to `_shared/pipeline.ts`; re-export), `organize/handler.ts`, `organize/index.ts`, tests' import paths
- Delete: `organize/deps.ts`, `organize/deps_test.ts`

**Interfaces:**
- Produces (`_shared/pipeline.ts`):
  ```ts
  export type ChatMessage = { role: "system" | "user"; content: string };
  export type Profile, Usage, Cause, LogEntry, Deps; // moved verbatim from organize/handler.ts
  export function parseModelOutput(text: string): unknown | null; // moved verbatim
  export type AiSpec<T, R> = {
    maxBytes: number;
    parse(raw: unknown): T | null;
    messages(req: T): ChatMessage[];
    validate(out: unknown, req: T): R | null;
  };
  export async function handleAi<T, R>(req: Request, deps: Deps, spec: AiSpec<T, R>): Promise<Response>;
  ```
  `handleAi` is today's `organize/handler.ts` `handle` body with the four organize calls replaced by `spec.*`. `organize/handler.ts` becomes `export const handle = (req: Request, deps: Deps) => handleAi(req, deps, organizeSpec);` plus re-exports of the moved types.

- [ ] **Step 1: Move and refactor** as above; behaviour must be identical.
- [ ] **Step 2: Run** `deno test --allow-env inknest/supabase/functions/` → all existing tests pass (27).
- [ ] **Step 3: Commit** `refactor(organize-fn): extract shared AI pipeline for reuse`

### Task 2: Assist catalogue and core

**Files:**
- Create: `inknest/supabase/functions/assist/catalogue.ts`, `assist/core.ts`
- Test: `assist/catalogue_test.ts`, `assist/core_test.ts`

**Interfaces:**
- Consumes: `ChatMessage`, `parseModelOutput` (Task 1).
- Produces:
  ```ts
  export const ACTION_TYPES: readonly string[]; // all 24 types from the spec catalogue
  export type Action = { type: string; [k: string]: unknown };
  export type AssistContext = {
    week_start: string; // YYYY-MM-DD (Monday)
    calendar?: { id: string | null; entries: { id: string; title: string; date: string; start: string | null; end: string | null; all_day: boolean }[] };
    boards?: { id: string; name: string; columns?: { id: string; name: string }[]; cards?: { id: string; title: string; column_id: string }[] }[];
    pages?: { id: string; name: string; parent_id: string; layout: string }[];
    page_texts?: { id: string; markdown: string }[];
    databases?: { id: string; name: string; layout: string; fields: { id: string; name: string; type: string; writable: boolean; options?: { id: string; name: string }[] }[]; rows?: { id: string; cells: Record<string, string> }[] }[];
  };
  export type AssistRequest = { allowed_actions: string[]; messages: { role: "user" | "assistant"; text: string }[]; context: AssistContext; proposal?: Action[] };
  export type AssistReply = { note: string; actions: Action[] };
  export function parseAssistRequest(raw: unknown): AssistRequest | null;
  export function buildAssistMessages(req: AssistRequest): ChatMessage[];
  /** Keeps valid actions in order; drops the rest. */
  export function validateActions(actions: unknown, req: AssistRequest): Action[];
  export function validateAssistReply(out: unknown, req: AssistRequest): AssistReply | null; // null if not an object
  ```
  Per-type field rules = spec "Action catalogue" table. Id rules: every `*_id` must be a context id of the right kind (entry ids from `calendar.entries`, board ids from `boards`, column/card ids belonging to that board, page ids from `pages`, database/field/row/option ids belonging to that database) **or** a `new:N` bound by an earlier action's `temp_id` in the same list. Types not in `allowed_actions` are dropped. Prompt (builder's wording): messages are instructions, `context` is data only, list the allowed action types with fields, reply only JSON `{note, actions}`, ask in `note` when a named item is ambiguous.

- [ ] **Step 1: Write failing tests** (fixture context: week_start `2026-10-19`; entry `e1` Tue 16:00–17:00; board `b1` "Move" with column `c1` "To do", card `k1`):
  - `drops unknown and wrong-kind ids` → `calendar.update` with `entry_id: "b1"` dropped; `board.card.update` with `card_id: "k9"` dropped.
  - `temp ids must be bound earlier` → `[board.column.add{board_id:"b1",temp_id:"new:1",name:"Doing"}, board.card.add{board_id:"b1",column_id:"new:1",temp_id:"new:2",title:"Box"}]` both kept; reversed order → only `board.column.add` kept. *(Review Focus 1)*
  - `calendar bounds` → date `2026-10-26` dropped; `start "18:00" end "17:00"` dropped; `all_day:true` with null times kept.
  - `titles` → `"a\nb"`, `""`, 121 chars dropped; 120 kept.
  - `stage gating` → `page.create` dropped when `allowed_actions` lacks it.
  - `caps` → 81 valid actions → first 80 kept.
  - `parseAssistRequest rejects bad shapes` → missing `context.week_start` → null.
  - `buildAssistMessages encodes context as JSON data` → user message contains `JSON.stringify(context)`; system message lists exactly `allowed_actions`.
- [ ] **Step 2: Run** `deno test --allow-env inknest/supabase/functions/assist/` → FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(assist-fn): add action catalogue and request validation`

### Task 3: Assist handler, deploy config, docs

**Files:**
- Create: `assist/handler.ts`, `assist/index.ts`, `assist/handler_test.ts`
- Modify: `inknest/supabase/config.toml` (add `[functions.assist]` `verify_jwt = false`), `inknest/README.md` (deploy `assist` with `--no-verify-jwt`; same secrets)

**Interfaces:**
- Produces: `export const handle = (req: Request, deps: Deps) => handleAi(req, deps, assistSpec)` with `maxBytes: 524288`; deployed URL `…/functions/v1/assist`.

- [ ] **Step 1: Write failing tests** (reuse the organize handler test helpers' style): 200 returns `{note, actions}` with invalid actions dropped; `prompt injection in a card title cannot add a disallowed type` (model returns `page.delete` while `allowed_actions` is stage 1 → dropped); 413 over 524288 bytes; 429 passes through; logs contain no context text.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `deno test --allow-env inknest/supabase/functions/` → all pass.
- [ ] **Step 5: Commit** `feat(assist-fn): add assist function handler and deploy config`

---

## Part B — App v1: schedule and boards

### Task 4: Models and store

**Files:**
- Create: `lib/features/assistant/data/assistant_models.dart`, `lib/features/assistant/data/assistant_store.dart`
- Modify: `lib/core/config/kv_keys.dart` (`static const String assistant = 'inknest.assistant';` with doc comment like `aiOrganize`)
- Test: `test/unit_test/assistant/assistant_store_test.dart`

**Interfaces:**
- Produces (all with `toJson`/`fromJson`; enums by `.name`; timestamps UTC):
  ```dart
  enum AssistStage { none, schedule, pages, workspace } // index = stage number
  class AssistAction { AssistAction({required this.type, required this.fields}); final String type; final Map<String, dynamic> fields; String? get tempId => fields['temp_id'] as String?; }
  class ChatTurn { ChatTurn({required this.role, required this.text}); final String role; /* 'user' | 'assistant' */ final String text; }
  class Proposal { Proposal({required this.id, required this.actions, required this.note, required this.weekStart, required this.labels, Set<int>? ticked, Map<int, Map<String, dynamic>>? edits}); // ticked defaults to all except destructive
    final String id; final List<AssistAction> actions; final String note; final String weekStart; final Map<String, String> labels; Set<int> ticked; Map<int, Map<String, dynamic>> edits; }
  class UndoRecord { UndoRecord({required this.type, required this.data}); final String type; final Map<String, dynamic> data; }
  enum AppliedStatus { applying, applied, partial, undone }
  class AppliedProposal { AppliedProposal({required this.id, required this.appliedAt, required this.actions, List<UndoRecord>? records, Map<String, String>? tempIds, this.status = AppliedStatus.applying, this.error});
    final String id; final DateTime appliedAt; final List<AssistAction> actions; /* ticked + edited, in order */ final List<UndoRecord> records; /* records.length == actions done */ final Map<String, String> tempIds; AppliedStatus status; String? error; }
  class AssistantState { bool enabled = true; AssistStage consentedStage = AssistStage.none; List<ChatTurn> thread; Proposal? proposal; List<AppliedProposal> applied; }
  class AssistantStore { AssistantStore({required KeyValueStorage kv, required String userId}); Future<AssistantState> load(); Future<void> save(AssistantState s); } // key '${KVKeys.assistant}.$userId'; keeps newest 20 applied, last 10 turns; corrupt data → log + fresh state
  ```
  On load, `applying` proposals become `partial` (Review Focus 2).

- [ ] **Step 1: Failing tests:** round trip; users isolated; `applying` → `partial` on load; trims to 20 applied / 10 turns; corrupt value → defaults.
- [ ] **Steps 2–4:** run `flutter test test/unit_test/assistant/assistant_store_test.dart | tail -3` → FAIL → implement → PASS.
- [ ] **Step 5: Commit** `feat(assistant): add assistant models and store`

### Task 5: Shared AI function client and AssistApi

**Files:**
- Create: `lib/features/ai_organize/data/ai_function_client.dart`, `lib/features/assistant/data/assist_api.dart`
- Modify: `lib/features/ai_organize/data/organize_api.dart` (use the shared client; behaviour unchanged)
- Test: `test/unit_test/assistant/assist_api_test.dart` (existing `organize_api_test.dart` must still pass)

**Interfaces:**
- Produces:
  ```dart
  /// POSTs JSON with Bearer token; 150 s timeout; maps failures exactly as OrganizeApi does today.
  Future<Map<String, dynamic>> postAiFunction({required http.Client client, required String url, required String token, required Map<String, dynamic> body}); // throws OrganizeApiException
  String assistUrlFrom(String organizeUrl); // replaces the last path segment with 'assist'; '' → ''
  class AssistReply { const AssistReply({required this.note, required this.actions}); final String note; final List<AssistAction> actions; }
  class AssistApi {
    AssistApi({required this.url, http.Client? client});
    Future<AssistReply> send({required String token, required Map<String, dynamic> body}); // malformed 200 → OrganizeApiException(failed)
  }
  ```
  `AssistAction` comes from Task 4 (`assistant_models.dart`).

- [ ] **Step 1: Failing tests:** `assistUrlFrom('https://x.supabase.co/functions/v1/organize') == '…/functions/v1/assist'`; `send parses note and actions`; `send maps 429 global_limit`; `malformed actions → failed`.
- [ ] **Step 2: Run** `flutter test test/unit_test/assistant/assist_api_test.dart test/unit_test/ai_organize/organize_api_test.dart | tail -3` → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(assistant): add assist API client on a shared AI function client`

### Task 6: Mentions and target week

**Files:**
- Create: `lib/features/assistant/logic/mentions.dart`
- Test: `test/unit_test/assistant/mentions_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class Mentionable { const Mentionable({required this.id, required this.name, required this.kind}); final String id; final String name; final String kind; /* 'board' | 'page' | 'database' */ }
  List<Mentionable> findMentions(String message, List<Mentionable> items); // whole name, case-insensitive, whole-word, name.trim().length >= 3; duplicates by name all returned
  DateTime targetWeekStart(DateTime now, String message); // Monday 00:00 local; 'next week' → next; 'this week' → this; else this week, or next week when now is Fri–Sun
  ```

- [ ] **Step 1: Failing tests:** `"set up my Move board"` matches "Move" not "Mo"; `"remove"` does not match "Move" (whole word); case-insensitive; two boards named "Home" both returned *(Review Focus 5)*; `targetWeekStart(Wed 2026-10-21, 'plan')` → 2026-10-19; `(Sat 2026-10-24, 'plan')` → 2026-10-26; `(Sat, 'this week')` → 2026-10-19; `(Wed, 'next week')` → 2026-10-26.
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add mention detection and target week`

### Task 7: Action contract and engine

**Files:**
- Create: `lib/features/assistant/logic/action_handler.dart`, `lib/features/assistant/logic/action_engine.dart`
- Test: `test/unit_test/assistant/action_engine_test.dart` (fake handlers only)

**Interfaces:**
- Produces:
  ```dart
  class ActionPreview { const ActionPreview({required this.text, this.before, this.after, this.destructive = false, this.editable = const []}); final String text; final String? before; final String? after; final bool destructive; final List<String> editable; /* field keys the UI may edit */ }
  enum UndoOutcome { reverted, skippedChanged, skippedGone }
  class ApplyScope { ApplyScope(this.tempIds); final Map<String, String> tempIds; String resolve(String id); /* new:N → real, else id */ void bind(String tempId, String realId); }
  abstract class ActionHandler {
    String get type; AssistStage get stage;
    String? validate(AssistAction a, Set<String> knownIds, Set<String> boundTemps); // null = valid
    ActionPreview describe(AssistAction a, Map<String, String> labels);
    Future<UndoRecord> apply(AssistAction a, ApplyScope scope); // throws on failure
    Future<UndoOutcome> undo(UndoRecord r);
  }
  class UndoReport { const UndoReport({required this.reverted, required this.skippedChanged, required this.skippedGone}); final int reverted, skippedChanged, skippedGone; }
  class ActionEngine {
    ActionEngine(List<ActionHandler> handlers);
    List<AssistAction> filterValid(List<AssistAction> actions, {required Set<String> knownIds, required AssistStage stage}); // order kept; tracks temp ids; drops unknown types / stage > allowed
    List<String> typesUpTo(AssistStage stage); // action types whose handler.stage <= stage (sent as allowed_actions)
    ActionPreview describe(AssistAction a, Map<String, String> labels);
    Future<void> apply(AppliedProposal p, {Future<void> Function()? onProgress}); // resumes at p.records.length; appends a record per success; stops on first throw → status partial + error; all done → applied
    Future<UndoReport> undo(AppliedProposal p); // reverse order; status undone
  }
  ```

- [ ] **Step 1: Failing tests:** `filterValid drops forward temp refs` *(RF1)*; `apply runs in order and binds temp ids`; `apply stops at first failure and reports partial` *(RF3)*; `apply resumes without re-running done actions` (records preset to 2 → handler called for 3rd onward only) *(RF2)*; `undo walks in reverse and counts outcomes`; `onProgress called after each action` (service persists there).
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add action contract and apply/undo engine`

### Task 8: Calendar gateway, actions, context

**Files:**
- Create: `lib/features/assistant/gateways/calendar_gateway.dart`, `lib/features/assistant/actions/calendar_actions.dart`
- Test: `test/unit_test/assistant/calendar_actions_test.dart` (mocktail `CalendarGateway`)

**Interfaces:**
- Produces:
  ```dart
  class CalendarEntry { const CalendarEntry({required this.id, required this.title, required this.start, required this.end, required this.allDay}); final String id; final String title; final DateTime start; final DateTime end; final bool allDay; }
  class CalendarGateway { // thin, not unit-tested; APIs per the Plan my week doc §App
    Future<String?> findMyWeek(); // oldest Calendar view named 'My Week'
    Future<String> ensureMyWeek(); // creates it in KVKeys.lastOpenedSpaceId (fallback: first space) if missing
    Future<List<CalendarEntry>> entries(String viewId, DateTime from, DateTime to);
    Future<CalendarEntry?> entry(String viewId, String rowId);
    Future<String> add(String viewId, CalendarEntry e); // createRow(title) then DateCellBackendService.update(isRange: true, includeTime: !allDay); if the date fails, delete the row and rethrow
    Future<void> update(String viewId, String rowId, CalendarEntry e);
    Future<void> remove(String viewId, String rowId);
  }
  List<ActionHandler> calendarHandlers(CalendarGateway gw); // calendar.add / .update / .remove
  Future<({Map<String, dynamic> json, Map<String, String> labels, Set<String> ids})> calendarContext(CalendarGateway gw, DateTime weekStart); // this + last week; 'My Week' is NOT created here
  ```
  `calendar.add` calls `ensureMyWeek()` on apply (spec: created only when applied). Undo records store the entry before/after; undo reverts only when `entry()` equals the stored "after"; `calendar.remove` undo re-adds with previous values.

- [ ] **Step 1: Failing tests:** add → `ensureMyWeek` + `add` called, record holds new id; update preview shows `Tue 16:00–17:00 → Wed 17:00–18:00`; remove preview `destructive: true`; `undo update skipped when user changed the entry since` *(RF4)*; undo remove re-adds; `calendarContext does not create My Week` (verifyNever ensureMyWeek).
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add calendar actions`

### Task 9: Board gateway, actions, context

**Files:**
- Create: `lib/features/assistant/gateways/board_gateway.dart`, `lib/features/assistant/actions/board_actions.dart`
- Test: `test/unit_test/assistant/board_actions_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class BoardColumn { const BoardColumn({required this.id, required this.name, required this.isDefault}); final String id, name; final bool isDefault; }
  class BoardCard { const BoardCard({required this.id, required this.title, required this.columnId}); final String id, title, columnId; }
  class BoardSnapshot { const BoardSnapshot({required this.id, required this.name, required this.columns, required this.cards, required this.editable}); final String id, name; final List<BoardColumn> columns; final List<BoardCard> cards; final bool editable; /* false when not grouped by a single-select field */ }
  class BoardGateway {
    Future<List<({String id, String name})>> boards(); // all Board views
    Future<BoardSnapshot?> board(String boardId, {int cardCap = 200});
    Future<String> createBoard(String name, List<String> columns); // current space; new board ends with exactly these columns (+ the default group) and no cards
    Future<void> deleteBoard(String boardId); // to Trash
    Future<void> restoreBoard(String boardId); // TrashService.putback
    Future<String> addColumn(String boardId, String name); // GroupBackendService.createGroup, then reload groups to find the new id
    Future<void> renameColumn(String boardId, String columnId, String name);
    Future<void> removeColumn(String boardId, String columnId);
    Future<String> addCard(String boardId, String columnId, String title); // createRow(groupId:) + primary text
    Future<void> updateCard(String boardId, String cardId, {String? title, String? columnId}); // moveGroupRow for column
    Future<void> removeCard(String boardId, String cardId);
  }
  List<ActionHandler> boardHandlers(BoardGateway gw); // the 7 board.* types
  Future<({Map<String, dynamic> json, Map<String, String> labels, Set<String> ids})> boardContext(BoardGateway gw, List<String> detailedBoardIds); // all names; ≤ 3 detailed
  ```
  Column names: select-option names of the grouping field (`GroupPB.groupId` = option id); default group label `No <field name>`. `board.column.remove` preview lists cards that will move; its undo re-adds the column and moves back cards still in the default group. Actions on a non-editable board fail validation.

- [ ] **Step 1: Failing tests:** create board binds temp id and passes exact columns; `card.add` into a `new:N` column resolves via scope; card move preview `To do → Doing`; `undo card.update skipped when renamed since` *(RF4)*; column remove preview lists card titles and is destructive; undo column remove re-adds and moves cards back.
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add board actions`

### Task 10: AssistantService

**Files:**
- Create: `lib/features/assistant/logic/assistant_service.dart`
- Test: `test/unit_test/assistant/assistant_service_test.dart`

**Interfaces:**
- Consumes: Tasks 4–9; `OrganizeBackend.accessToken` pattern; `Env.inknestOrganizeUrl` + `assistUrlFrom`.
- Produces:
  ```dart
  const AssistStage kBuiltStage = AssistStage.schedule; // Task 14 → pages, Task 16 → workspace
  class AssistantService {
    AssistantService({required AssistantStore store, required AssistApi api, required ActionEngine engine, required CalendarGateway calendar, required BoardGateway boards, required Future<String?> Function() accessToken, DateTime Function()? now});
    static Future<AssistantService?> current(); // null when URL empty or no token; cached per user id
    static Future<bool> isAvailable(); // current() != null && enabled
    Future<AssistantState> state();
    Future<void> setEnabled(bool enabled);
    Future<void> setConsentedStage(AssistStage stage);
    AssistStage get activeStage; // min(kBuiltStage, consentedStage)
    Future<List<Mentionable>> mentionsFor(String message, {List<String> pinnedIds = const []});
    Future<Proposal> send(String message, {required List<String> mentionIds}); // throws OrganizeApiException; failed when !enabled or activeStage == none
    Future<AppliedProposal> apply(); // current proposal's ticked + edited actions; persists after each action
    Future<AppliedProposal> retry(String appliedId); // resumes a partial one
    Future<UndoReport> undo(String appliedId);
    Future<void> clearConversation();
  }
  ```
  `send`: append user turn; build context (calendar always; boards: names + detail for `mentionIds`; later stages add parts); body `{allowed_actions: <types with stage ≤ activeStage>, messages: last 10 turns, context, proposal: current?}`; on 401 re-read token once; `engine.filterValid` on the reply; store proposal + assistant turn. `apply`: synchronous double-tap guard (in-memory set, like Organize), `AppliedProposal` saved before the first action and after each.

- [ ] **Step 1: Failing tests:** `send refused when disabled or not consented` (api never called); `send posts only allowed action types for the active stage`; `follow-up sends the current proposal`; `client re-validation drops actions the server let through`; `apply twice concurrently applies once`; `apply persists after each action`; `retry resumes partial`; `undo marks undone`.
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add assistant service`

### Task 11: Strings and shared assistant view

**Files:**
- Modify: `frontend/resources/translations/en-US.json` (top-level `"assistant"`)
- Create: `lib/features/assistant/presentation/assistant_view.dart`, `proposal_preview.dart`, `assistant_errors.dart`
- Test: `test/widget_test/assistant/proposal_preview_test.dart`, `test/widget_test/assistant/assistant_view_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class ProposalPreview extends StatefulWidget { const ProposalPreview({super.key, required this.proposal, required this.describe, required this.onApply}); final Proposal proposal; final ActionPreview Function(AssistAction) describe; final void Function(Set<int> ticked, Map<int, Map<String, dynamic>> edits) onApply; }
  class AssistantView extends StatefulWidget { const AssistantView({super.key, required this.service, this.pinnedIds = const []}); } // thread, mention chips (removable), input + Send, working state, ProposalPreview, Recent list with Undo/Retry, quick chips
  String assistantErrorKey(OrganizeErrorKind kind); bool assistantCanRetry(OrganizeErrorKind kind); // same rules as organize_errors.dart
  ```
  Strings (key → text; consent is fixed by the spec):
  `title` "Ask InkNest", `placeholder` "Tell me what to do…", `send` "Send", `working` "Working… this can take a minute", `using` "Using", `applySelected` "Apply selected", `discard` "Discard", `done` "Done — {} changes", `appliedPartial` "Applied {} of {}", `retry` "Retry", `undo` "Undo", `undone` "Undone — {} reverted, {} kept because you changed them", `recent` "Recent", `planWeek` "Plan my week", `newBoard` "New board", `newPage` "New page", `enabled` "Ask InkNest", `failed` "Couldn't get an answer", `userLimit` "Daily AI limit reached. Try again tomorrow.", `globalLimit` "AI is busy today. Try again tomorrow.", `notInvited` "Ask InkNest is invite-only. Ask the InkNest owner for access.", `signInAgain` "Sign in again to use Ask InkNest", `nothing` "Nothing to change", `consentTitle` "Let Ask InkNest see your items?", `consentStage1` (spec consent, v1 bracket set), `consentStage2` (+ page list and pages you mention), `consentStage3` (+ tables you mention), `consentAccept` "Continue".

- [ ] **Step 1: Strings + codegen** — `frontend/scripts/code_generation/language_files/generate_language_files.sh` (with the Flutter PATH prefix).
- [ ] **Step 2: Failing widget tests:** destructive rows render with the error colour and start unticked; only ticked indexes reach `onApply`; editing a title passes `edits[i]['title']`; removing a chip excludes its id from `send` (mock service); declining consent sends nothing.
- [ ] **Steps 3–5** → FAIL → implement → PASS (`flutter test test/widget_test/assistant/ | tail -3`). **Step 6: Commit** `feat(assistant): add assistant view and proposal preview`

### Task 12: Desktop entry points

**Files:**
- Create: `lib/features/assistant/presentation/assistant_dialog.dart`, `ask_inknest_button.dart`
- Modify: `lib/workspace/presentation/home/menu/sidebar/sidebar.dart:378-382` (button after `SidebarNewPageButton`, same not-Guest block), `lib/plugins/database/tab_bar/tab_bar_view.dart:477` (`rightBarItem` — before `ShareButton`, pins the view), `lib/plugins/document/document.dart:189` (`rightBarItem`, same), desktop AI settings page (switch row; locate the widget titled `LocaleKeys.settings_aiPage_title`)

**Interfaces:**
- Produces: `Future<void> showAssistantDialog(BuildContext context, {List<String> pinnedIds = const []});` — `showDialog` + `AFModal(constraints: BoxConstraints(maxWidth: AFModalDimension.L, maxHeight: 640))` hosting `AssistantView`. `AskInkNestButton({List<String> pinnedIds})` hidden unless `AssistantService.isAvailable()`. Sidebar button copies `_SidebarSearchButton` (`sidebar.dart:548`) with `FlowySvgs.ai_sparks_s`.

- [ ] **Step 1: Implement.** **Step 2: Analyze** `flutter analyze lib/features/assistant lib/workspace/presentation/home/menu/sidebar lib/plugins/database/tab_bar lib/plugins/document` → No issues found. **Step 3: Run** `flutter test test/unit_test/assistant/ test/widget_test/assistant/ | tail -3` → pass. **Step 4: Commit** `feat(assistant): add desktop entry points`

### Task 13: Mobile entry points

**Files:**
- Create: `lib/features/assistant/presentation/assistant_sheet.dart`, `assistant_settings_group.dart`
- Modify: `lib/mobile/presentation/home/mobile_home_setting_page.dart:107` (group after `AiOrganizeSettingsGroup`), `lib/mobile/presentation/bottom_sheet/bottom_sheet_view_page.dart` (enum `askInkNest`; item after the `aiOrganize` item for any layout when available), `lib/mobile/presentation/base/view_page/more_bottom_sheet.dart:71` (case → `showAssistantSheet(context, pinnedIds: [view.id])`), `lib/plugins/database/tab_bar/mobile/mobile_tab_bar_header.dart:28-58` (button before `MobileDatabaseControls`)

**Interfaces:**
- Produces: `Future<void> showAssistantSheet(BuildContext context, {List<String> pinnedIds = const []});` (full-height `showMobileBottomSheet`); `AssistantSettingsGroup` (switch + "Open Ask InkNest"; hidden when `current()` is null).

- [ ] **Step 1: Implement.** **Step 2: Analyze** touched paths → No issues found. **Step 3: Run** assistant tests → pass. **Step 4: Commit** `feat(assistant): add mobile entry points`

---

## Part C — v2: pages with content

### Task 14: Page gateway, page.create / page.append, page context

**Files:**
- Create: `lib/features/assistant/gateways/page_gateway.dart`, `lib/features/assistant/actions/page_content_actions.dart`
- Modify: `assistant_service.dart` (constructor gains `required PageGateway pages`; `kBuiltStage = AssistStage.pages`; context adds `pages` + `page_texts` for mentioned pages; mentionables include pages; consent stage 2)
- Test: `test/unit_test/assistant/page_content_actions_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class PageRef { const PageRef({required this.id, required this.name, required this.parentId, required this.layout, required this.editable}); final String id, name, parentId, layout; final bool editable; /* false when locked */ }
  class PageGateway {
    Future<List<PageRef>> tree({int cap = 500});
    Future<PageRef?> page(String id); // null when missing or in Trash
    Future<String?> markdown(String pageId, {int cap = 8000}); // DocumentService.getDocument → toDocument → customDocumentToMarkdown
    Future<String> createPage(String parentId, String name, String markdown); // createView(initialDataBytes: DocumentDataPBFromTo.fromDocument(customMarkdownToDocument(md))!.writeToBuffer()) as ChatEditDocumentService.saveMessagesToNewPage
    Future<List<String>> append(String pageId, String markdown); // as ChatEditDocumentService.addMessagesToPage; returns inserted block ids
    Future<bool> removeBlocksIfUnchanged(String pageId, List<String> blockIds, String expectedMarkdown);
    Future<void> delete(String pageId); Future<void> restore(String pageId); // Trash / putback (trash id == view id)
  }
  List<ActionHandler> pageContentHandlers(PageGateway gw); // page.create, page.append
  ```

- [ ] **Step 1: Failing tests:** create binds temp id and parent resolves `new:N`; append undo removes blocks when unchanged; `append undo skipped when the user edited those blocks` *(RF4)*; actions on non-editable pages fail validation; service sends `page_texts` only for mentioned pages and only when consented to stage 2.
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add page creation and append (v2)`

---

## Part D — v3: whole workspace

### Task 15: Page workspace actions

**Files:**
- Create: `lib/features/assistant/actions/page_workspace_actions.dart`
- Modify: `page_gateway.dart` (`rename`, `move(pageId, parentId, prevId)`, `duplicate(pageId) → id`, `setFavorite(pageId, bool)`; reads `isFavorite`, parent, prev sibling)
- Test: `test/unit_test/assistant/page_workspace_actions_test.dart`

**Interfaces:**
- Produces: `List<ActionHandler> pageWorkspaceHandlers(PageGateway gw);` — page.rename, page.move, page.duplicate, page.favorite, page.delete. Undo: rename back / move back to parent+prev sibling / delete copy / toggle back / `restore`. Each undo skipped when the page changed since (name, parent) or is gone.

- [ ] **Step 1: Failing tests:** delete preview destructive; delete undo calls `restore`; move undo restores parent and prev sibling; rename undo skipped when renamed since; locked pages fail validation.
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add page workspace actions (v3)`

### Task 16: Database gateway and actions; enable stage 3

**Files:**
- Create: `lib/features/assistant/gateways/database_gateway.dart`, `lib/features/assistant/actions/database_actions.dart`
- Modify: `assistant_service.dart` (constructor gains `required DatabaseGateway databases`; registers `pageWorkspaceHandlers` from Task 15; `kBuiltStage = AssistStage.workspace`; context adds `databases` for mentioned grids/boards/calendars; consent stage 3)
- Test: `test/unit_test/assistant/database_actions_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class DbField { const DbField({required this.id, required this.name, required this.type, required this.writable, this.options = const []}); final String id, name; final FieldType type; final bool writable; final List<({String id, String name})> options; }
  class DbSnapshot { const DbSnapshot({required this.id, required this.name, required this.layout, required this.fields, required this.rows}); final String id, name; final ViewLayoutPB layout; final List<DbField> fields; final List<({String id, Map<String, String> cells})> rows; }
  class DatabaseGateway {
    Future<List<({String id, String name, ViewLayoutPB layout})>> databases();
    Future<DbSnapshot?> snapshot(String dbId, {int rowCap = 200}); // rows via DatabaseEventGetAllRows + CellBackendService.getCell per field
    Future<String> createDatabase(String parentId, String name, ViewLayoutPB layout, List<({String name, FieldType type})> fields);
    Future<String> addRow(String dbId, Map<String, String> cells); Future<void> updateRow(String dbId, String rowId, Map<String, String> cells); Future<void> removeRow(String dbId, String rowId);
    Future<Map<String, String>?> row(String dbId, String rowId);
    Future<String> addField(String dbId, String name, FieldType type); Future<void> renameField(String dbId, String fieldId, String name); Future<void> removeField(String dbId, String fieldId);
    Future<String> addOption(String dbId, String fieldId, String name); // type-option write (nanoid(4) id), as select_type_option_actions.dart:114 — never via SelectOptionCellBackendService.create
    Future<void> removeOption(String dbId, String fieldId, String optionId);
  }
  List<ActionHandler> databaseHandlers(DatabaseGateway gw); // database.create, row.add/update/remove, field.add/rename, option.add
  ```
  Cell writes: text/number `updateCell(data)`; checkbox `"Yes"/"No"`; select/multi-select by option name → id (unknown name fails validation); date via `DateCellBackendService.update`. Writes to non-writable fields fail validation; `row.remove` fails validation when any non-empty cell is non-writable.

- [ ] **Step 1: Failing tests:** row.update preview before → after per cell; write to a URL field rejected; `row.remove` rejected for a row with a non-empty relation cell; undo row.update restores only writable cells and is skipped when changed since; option.add never selects a row (verifyNever on any row write).
- [ ] **Steps 2–4** → FAIL → implement → PASS. **Step 5: Commit** `feat(assistant): add database actions and enable stage 3 (v3)`

---

## Part E — Owner session (deferred, needs the owner)

### Task 17: Deploy and device acceptance

- [ ] Deploy `organize` and `assist` per `inknest/README.md` (Supabase project, `supabase login`, secrets, `--no-verify-jwt`); add the owner to `organize_allowlist`.
- [ ] Put `INKNEST_ORGANIZE_URL=…/functions/v1/organize` in `frontend/appflowy_flutter/.env` (never commit), rebuild the Mac app and the APK.
- [ ] Walk the spec's Acceptance 1–19 on the Mac and the S24; record pass/fail per item in the PR.
