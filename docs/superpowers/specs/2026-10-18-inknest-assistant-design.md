# InkNest Assistant — Design (v1 → v2 → v3)

Date: 2026-10-18
Status: Approved by owner, 2026-10-18
Supersedes: `2026-10-18-inknest-plan-my-week-design.md` (Plan my week is one job of the assistant)
Builds on: `2026-10-18-inknest-ai-organize-design.md` (server, key, allowlist, limits, approve-first pattern — implemented)

## Intent

The owner wants an AI they can talk to that **does things in the app**, not just writes text:
plan their week, change their schedule, set up boards with tasks, and eventually work with
the whole app. AppFlowy's built-in chat can only write text (verified in code: it can chat,
use pages as sources, change answer format, and save an answer into a page — it cannot
create entries, rows, boards, or change pages).

One design, built in three stages in order, approved once:

| Stage | Can |
|---|---|
| **v1** | plan the week; add / move / rename / remove calendar entries; create boards; add / move / rename / remove cards and columns |
| **v2** | create pages with content (notes, checklists, outlines); append content to an existing page |
| **v3** | rename / move / duplicate / favorite / delete pages (delete = to Trash); create grids, boards, calendars; add / edit / remove rows in any grid or board; add / rename fields and select options |

Each stage only adds entries to the action catalogue (and, where noted, context); the
assistant, server, preview, apply, and undo machinery is built once in v1.

## Decisions made by the owner

- InkNest's own assistant box, not AppFlowy's built-in AI chat (that stays as is).
- On the Mac and the S24.
- AI = owner's NaraRouter (Agnes 3 Flash) through the InkNest Supabase server.
- It acts on the app: plan the week, **edit the schedule**, set up and manage boards with
  tasks — and eventually interact with all of the app.
- Conversation: the user can refine with follow-ups ("make it 3 columns").
- Their week is mostly a repeated routine with small changes.
- From the Plan my week playback: week starts Monday; device local time; a "My Week"
  calendar; it uses last week's entries as the routine and avoids clashes.
- Work order v1 → v2 → v3, all in one design.
- Every change needs the user's approval and can be undone. Deleting is allowed with
  approval (Claude's stated assumption; the owner did not object).

## Goals (all stages)

1. **Ask InkNest box** on desktop and mobile: a short conversation thread, a text field
   (typing or the OS's own voice/handwriting input), Send.
2. The AI answers with a **proposal**: an ordered list of typed actions plus one short note.
   A follow-up message revises the current proposal (thread + current proposal are sent back).
3. **Preview**: each action is a row with a checkbox, a plain description, before → after for
   changes; removals and deletions visibly marked. Fields of add/change actions are editable.
4. **Apply selected** runs only the ticked actions, in order, idempotently.
5. **Undo** per applied proposal: reverses its actions in reverse order; anything the user
   changed by hand since is skipped and reported.
6. Quick-start chips: "Plan my week", "New board" (v1), "New page" (v2).
7. Own on/off switch and first-use consent; consent is asked again when a stage widens what
   is sent (v2, v3).
8. The open conversation and proposal survive closing the box.

## Non-goals

- AppFlowy's built-in AI chat; acting without approval; scheduled/automatic runs.
- Recurring events, reminders, external calendar sync.
- Editing existing text inside a page (v2 only creates pages and appends at the end).
- Permanently deleting anything (v3 delete moves to Trash; emptying Trash stays manual).
- Workspace/member/sharing/publishing settings, AI Organize (stays its own feature).

## Anti-goals

- Any change applied without Apply selected.
- An action touching an item the AI was not shown (unknown ids are dropped).
- Undo that overwrites a change the user made after the proposal was applied.
- Page text sent to the AI unless the user mentioned that page (v2+).
- The NaraRouter key in the app; content stored or logged on the server.

## What the AI can see (context)

Only this, per message:

- **v1 — Calendar:** "My Week" entries for the target week and the week before (id, title,
  date, start, end, all_day). Target week = the week the user names; default this week
  (next week on Fri–Sun).
- **v1 — Boards:** names + ids of all Board views; for boards the user mentions by name
  (case-insensitive) or that the current proposal touches: columns (id, name, order) and
  cards (id, title, column id). Caps: 200 cards per board, 3 boards per message.
- **v2 — Pages:** the page tree (id, name, parent, layout; cap 500) and, for pages the user
  mentions by name, their text as markdown (cap 8,000 chars per page, 3 pages).
- **v3 — Databases:** for grids/boards the user mentions: fields (id, name, type, select
  options) and rows (id, cell values as text; cap 200 rows).
- The conversation so far (last 10 turns) and the current proposal.

The AI refers to items only by ids it was given; items it creates get temporary ids
(`new:1`, …) that later actions in the same proposal can reference.

## Action catalogue

Each action type has a JSON schema (server-validated, re-checked in the app), a preview
line, an executor, and an inverse for Undo.

**v1 — schedule and boards**

| Action | Fields | Inverse |
|---|---|---|
| `calendar.add` | title, date, start, end, all_day | delete the created entry |
| `calendar.update` | entry_id, any of title/date/start/end/all_day | restore previous values |
| `calendar.remove` | entry_id | re-create with previous values (new id) |
| `board.create` | temp_id, name, columns[] | delete the board page |
| `board.column.add` | board_id, temp_id, name | delete the column |
| `board.column.rename` | board_id, column_id, name | rename back |
| `board.column.remove` | board_id, column_id | re-create column; move its cards back |
| `board.card.add` | board_id, column_id, temp_id, title | delete the card |
| `board.card.update` | board_id, card_id, title?, column_id? | restore title / column |
| `board.card.remove` | board_id, card_id | re-create card (title, column) |

**v2 — pages with content**

| Action | Fields | Inverse |
|---|---|---|
| `page.create` | temp_id, parent_id (space or page), name, content (markdown: headings, paragraphs, bullet/numbered lists, to-do items) | delete the page (to Trash) |
| `page.append` | page_id, content (markdown) | remove the appended blocks if unchanged |

**v3 — whole workspace**

| Action | Fields | Inverse |
|---|---|---|
| `page.rename` | page_id, name | rename back |
| `page.move` | page_id, parent_id, after_id? | move back (parent + previous sibling) |
| `page.duplicate` | page_id, temp_id | delete the copy |
| `page.favorite` | page_id, on/off | toggle back |
| `page.delete` | page_id | restore from Trash |
| `database.create` | temp_id, parent_id, name, layout (grid/board/calendar), fields[] | delete it |
| `row.add` | database_id, temp_id, cells{field_id: value} | delete the row |
| `row.update` | database_id, row_id, cells{…} | restore previous cell values |
| `row.remove` | database_id, row_id | re-create with previous cells |
| `field.add` | database_id, temp_id, name, type (text/number/date/select/multi-select/checkbox) | delete the field |
| `field.rename` | database_id, field_id, name | rename back |
| `option.add` | database_id, field_id, name | delete the option |

Rules for all: ≤ 80 actions per proposal; names/titles one line ≤ 120 chars; calendar dates
inside the target week; ids must come from context or a `new:N` defined earlier in the same
proposal; locked pages and pages the user can't edit are never targets (dropped).
Destructive actions (`*.remove`, `page.delete`, removing a non-empty column) are shown in red
with what they affect (e.g. cards that will move to "No status").

## Architecture

### Server: Edge Function `assist`

Same auth, allowlist, shared daily usage counter (one count per message, shared with
Organize), error codes, and no-content logging as `organize`. Request:
`{ stage_actions: [...allowed action types], messages: [{role, text}], context: {...},
proposal?: [...], week_start }`. Response: `{ note, actions: [...] }`. Body cap 512 KB.
One NaraRouter call per message (40–80 s with Agnes; the app shows "Working… this can take
a minute"). The user's messages are instructions; `context` is data only. No tools — the
model returns the action list as JSON; the server validates each action against the
catalogue and drops invalid ones. Stages are enabled by the app sending only the action
types it supports, so the server can ship all three stages at once.

### App (Dart only, no Rust changes)

`lib/features/assistant/`:
- **Context builder** — My Week (calendar APIs in the Plan my week doc), boards
  (`getAllViews` → `ViewLayoutPB.Board`; columns = groups via `DatabaseViewBackendService`
  / `GroupBackendService`; cards = rows), page tree and mentioned page text (v2), database
  fields/rows (v3).
- **Action registry** — one class per action type: `validate`, `describe`, `apply` →
  undo record, `undo(record)` with a "changed since?" check. Registering a class is how a
  stage adds capability.
- **Executors** use existing services:
  - Calendar/rows: `RowBackendService.createRow/deleteRows`, `DateCellBackendService.update`,
    `CellBackendService.updateCell`.
  - Columns/cards: `GroupBackendService.createGroup/updateGroup/deleteGroup`,
    `DatabaseViewBackendService.moveGroupRow`.
  - Pages: `ViewBackendService.createView` (with `initialDataBytes` from
    `customMarkdownToDocument` → `DocumentDataPBFromTo`, as in
    `ChatEditDocumentService.saveMessagesToNewPage`), append like
    `ChatEditDocumentService.addMessagesToPage`, `updateView` (rename),
    `moveViewV2`, `duplicate`, `favorite`, `deleteView`; undo delete via `TrashService.putback`.
  - Fields/options: existing field and select-option services.
- **Store** — per user, per device (KV): enabled, consented stage, current thread +
  proposal, last 20 applied proposals with undo records (and temp-id → real-id map).
- **API client** — `AssistApi`, 150 s timeout, same error mapping as Organize.

Applying: mark the proposal `applying` synchronously (double-tap guard), run ticked actions
in order, store each undo record and temp-id mapping as it succeeds; on failure stop, keep
what ran (undoable), report "Applied N of M". Retry continues from the first action not yet
done, using the stored temp-id map, so nothing is created twice.

Undo: walk records in reverse; re-read each item; if it still matches the "after" state,
apply the inverse; otherwise skip and report. Items already gone are skipped.

### UI

- **Desktop:** "Ask InkNest" button in the sidebar under New page (Search-button style) →
  dialog (`AFModal`): thread on top, proposal preview, input at the bottom. An "Ask InkNest"
  button in board, calendar, grid and page headers pre-mentions that item.
- **Mobile:** "Ask InkNest" in the mobile AI settings area (switch + consent there too) and in
  the page "…" menu / board and calendar headers → full-height bottom sheet, same layout.
- After apply: toast "Done — N changes" with Undo; a "Recent" list in the box with Undo per
  proposal.
- **Consent** (shown at first use, and again when a new stage widens what is sent):
  "InkNest Assistant sends what you type, and the items it needs to work on — your My Week
  entries and the boards you mention[, the page list and pages you mention][, and the
  tables you mention] — to InkNest's server and to NaraRouter (and the AI model provider
  behind it). InkNest's server does not store them. NaraRouter's and the provider's own
  data policies apply."

## Acceptance

v1:
1. Nothing changes before Apply selected; only ticked actions run, with the user's edits.
2. "Plan my week like last week but gym Thursday" yields last week's routine with that change.
3. "Move my dentist to Wednesday 5pm" proposes one `calendar.update` with before → after.
4. "Set up a board for my move with To do / Doing / Done and packing tasks" creates one board
   with exactly those columns and the cards in To do.
5. A follow-up ("add a Blocked column") revises the proposal instead of starting over.
6. Destructive actions are marked; removing a non-empty column warns which cards move.
7. Unknown ids or out-of-week dates never reach the preview.
8. Apply twice / retry never duplicates.
9. Undo restores moved/renamed/removed items; items the user changed since are kept and reported.
10. Switch off hides the assistant everywhere on that device and sends nothing.
11. Works on Mac and S24; changes sync through AppFlowy.
12. AI failure or limit: clear message, Retry where it helps, nothing applied.

v2:
13. "Make a packing checklist page in my Move board's space" creates a page with to-do items.
14. "Add these notes to my Trip page" appends at the end; existing text is untouched.
15. Only pages the user mentioned have their text sent.

v3:
16. Rename / move / duplicate / favorite / delete pages work, delete goes to Trash, Undo restores.
17. "Make a reading list table with Title, Author, Status" creates a grid with those fields.
18. Row and field edits in a mentioned grid show before → after and undo cleanly.
19. Locked pages and pages the user can't edit are never changed.

## Left to the builder

- Widget layout, file split, state management (follow Organize patterns).
- Prompt wording; trimming the thread to fit.
- Reading board/grid rows and cells efficiently.
- Where the desktop switch lives (desktop AI settings page is fine).
- Order of building action classes within a stage.

## Calls made by Claude (please check)

- One design, three stages, built in order; each stage is usable on its own when it lands.
- Deleting is allowed with approval, always to Trash (never permanent); destructive rows are red.
- The AI sees only what's listed under "What the AI can see"; page text only for pages you mention.
- Removing a column moves its cards to "No status" (AppFlowy's behaviour); Undo moves them back.
- `board.create` replaces the new board's default columns with the requested ones.
- Boards not grouped by a single-select field are listed but can't be edited in v1.
- New boards, pages and tables go in the current space unless you name a parent.
- "My Week" is created only when a calendar action is applied, never earlier.
- Shares the daily AI limit with Organize; separate on/off switch and consent.
- Conversation, proposal, and Undo history are stored per device.
- If several items share a name, the assistant asks which one in its note instead of guessing.
- v2 never edits existing page text, only creates pages and appends at the end.
- "Mentioned" = the item's whole name appears in the message (case-insensitive, whole-word,
  names of 3+ characters), or it was pre-mentioned by a header button. Before sending, the box
  shows the picked-up items as chips ("Using: Trip page ✕") so the user can remove any; only
  the remaining ones are sent.
- v3 cells: text, number, date, select, multi-select and checkbox are writable; every other
  field type (URL, checklist, relation, media, time, …) is sent as read-only text and never
  written. `row.remove` is only allowed for rows whose non-empty cells are all writable types,
  so Undo can restore them exactly; other rows are dropped with a note.
- Consent is per stage: declining a later stage keeps the assistant working at the highest
  stage consented to; the app sends only that stage's action types and context.
