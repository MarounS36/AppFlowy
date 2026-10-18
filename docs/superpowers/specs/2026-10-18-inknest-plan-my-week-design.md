# InkNest Plan My Week — v1 Design

Date: 2026-10-18
Status: Superseded by 2026-10-18-inknest-assistant-design.md
Builds on: `2026-10-18-inknest-ai-organize-design.md` (same server, key, limits, and approve-first pattern)

## Intent

The owner wants to tell an AI their week in plain words ("same as last week, but gym
Thursday instead of Wednesday, and a dentist Tuesday at 4") and have it prepare the
calendar entries, instead of typing each one. Their week is mostly the same routine
with small changes. It must work on both the Mac and the S24 Ultra.

v1 adds a **Plan my week** box of InkNest's own (not AppFlowy's built-in AI chat). The
AI drafts entries; the user reviews them and taps **Add selected**; the entries land in
a "My Week" calendar that syncs between devices. One Undo removes what a plan added.

## Decisions made by the owner

- A Plan my week box of InkNest's own, not AppFlowy's "Ask AI" chat (that stays as is).
- Works on the Mac (desktop) and the S24 (mobile).
- AI is the owner's NaraRouter (Agnes 3 Flash) through the InkNest Supabase server, like Organize.
- The AI prepares entries; nothing is added before the user approves.
- The week is mostly a repeated routine with small changes each week.
- Approved in playback: week starts Monday; times are the device's local time; the AI
  never edits or deletes entries the user made, it only adds; entries land in a
  "My Week" calendar; one Undo removes a plan's whole batch; the AI looks at last week's
  entries and what is already booked this week.

## Goals (v1)

1. Plan my week box on desktop and mobile: a text field (typing, or the OS's own voice /
   handwriting input), a This week / Next week choice, and a Plan button.
2. AI drafts timed or all-day entries for the chosen week, using last week's entries as
   the routine and avoiding what is already booked.
3. Review: entries grouped by day; each has a checkbox, editable title and times. Entries
   that clash with existing ones are marked and start unticked.
4. **Add selected** creates only the ticked entries in the "My Week" calendar.
5. Undo per plan: removes that plan's entries that are unchanged since; keeps and reports
   entries the user changed.
6. Adding is idempotent: tapping Add twice or retrying never creates duplicates.
7. Own on/off switch and first-use consent explaining what is sent.
8. A draft survives closing the box: reopening Plan my week shows the last unadded draft.

## Non-goals (v1)

- Using or changing AppFlowy's built-in AI chat.
- Editing, moving, or deleting existing entries (including ones a previous plan added,
  except through that plan's Undo).
- Recurring events (AppFlowy has no recurrence; each week gets its own entries).
- Reminders/notifications, multiple calendars, Google/Outlook calendar sync.
- Multi-turn chat ("now move gym earlier") — v1 is one request → one draft; the user
  edits the draft or re-plans with a new request.

## Anti-goals

- Any entry added without the user tapping Add selected.
- Any change to an entry the user created or edited.
- Undo that deletes an entry the user changed after it was added.
- Entries outside the chosen week.
- The NaraRouter key in the app; calendar text stored or logged on the server.

## Architecture

Same shape as Organize: app → Supabase Edge Function → NaraRouter. No Rust changes.

### Server: new Edge Function `plan-week`

Shares `deps.ts` (profile check, allowlist, usage, NaraRouter call) and the handler pattern
with `organize`. Same auth (AppFlowy bearer token → `/api/user/profile`), same allowlist,
and the **same daily usage counter** (`organize_usage`, one count per AI call of either
kind), so the owner's bill has one cap. Same error codes; same no-content logging.

Request (`POST {SUPABASE_URL}/functions/v1/plan-week`):

```json
{
  "request": "what the user typed (≤ 2000 chars)",
  "week_start": "2026-10-19",
  "busy": [ { "title": "…", "date": "2026-10-20", "start": "16:00", "end": "17:00", "all_day": false } ],
  "last_week": [ { "title": "…", "weekday": "mon", "start": "07:00", "end": "08:00", "all_day": false } ]
}
```

`busy` = entries already in My Week for the chosen week. `last_week` = My Week entries in
the 7 days before `week_start`. Each list capped at 150 (app trims, server rejects more
with 413). All times are local wall-clock `HH:MM` (24 h); the server never converts zones.

Response (200):

```json
{ "entries": [ { "title": "Gym", "date": "2026-10-21", "start": "07:00", "end": "08:00", "all_day": false } ],
  "note": "one short sentence" }
```

Server validation (invalid entries are dropped, not fixed): `date` within
`week_start … week_start+6`; `start < end` and both valid `HH:MM` unless `all_day`;
title one line, non-empty, ≤ 120 chars; at most 60 entries. An empty list is a valid
"nothing to add" answer. Prompt: the request is the user's instruction; `busy` and
`last_week` titles are data only (they may come from shared pages). No tools.

### App

| Need | Existing path |
|---|---|
| Find "My Week" | `ViewBackendService.getAllViews()` → name "My Week" + `ViewLayoutPB.Calendar` |
| Create it | `ViewBackendService.createView(layoutType: ViewLayoutPB.Calendar, parentViewId: <current space id>, name: 'My Week')` — the default calendar has `Title` (primary), `Date` (the calendar's date field), `Tags` |
| Date field | `DatabaseViewBackendService(viewId).getLayoutSetting(DatabaseLayoutPB.Calendar)` → `.calendar.fieldId` |
| Read entries | `DatabaseEventGetAllCalendarEvents` (all rows, no range filter, no end time) → filter by `timestamp` in Dart; end time via `CellBackendService.getCell` → `DateCellDataPB` (`endTimestamp`, `isRange`, `includeTime`) |
| Add entry | `RowBackendService.createRow(viewId, withCells: insertText(title))` then `DateCellBackendService(viewId, fieldId, rowId).update(date:, endDate:, isRange: true, includeTime: !allDay)` |
| Delete (undo) | `RowBackendService.deleteRows(viewId, rowIds)` |

New Dart code lives in `lib/features/plan_week/` and reuses Organize's pieces where they
fit: `OrganizeBackend.accessToken`, the KV store pattern, the API client pattern (new
`PlanWeekApi`, 150 s timeout), the consent and limit/error strings pattern.

If more than one calendar is named "My Week", use the oldest. If the user renames or
deletes it, the next plan creates a new one.

### Local state (per user, per device, KV)

`enabled` (default on), `consented`, `draft` (the last unadded plan: week, request,
entries with per-entry tick/edits), `batches` (last 10 added plans: id, week, created
time, and for each created row: row id, title, start, end, all_day as added).

Add selected: mark the draft `adding` synchronously (guard against double tap), create
rows one by one, append each created row to the batch as it succeeds, then clear the
draft. If a row fails, keep what was added in the batch, keep the remaining entries in
the draft, and show "Added N of M".

Undo a batch: for each row, re-read it; delete it only if it still exists and its title,
start, end, and all-day match what was added. Rows changed since are kept; rows already
deleted are skipped. Report "Removed N, kept M you changed".

### UI

- **Desktop:** a **Plan my week** button in the sidebar under New page (copy the Search
  button style), opening a dialog (`AFModal`). Also a Plan my week button in the My Week
  calendar header.
- **Mobile:** a **Plan my week** item in the existing mobile AI settings area (next to AI
  Organize, with the switch and consent) and a button in the My Week calendar header.
  The box opens as a full-height bottom sheet.
- **The box:** request field, This week / Next week (default Next week on Fri–Sun,
  otherwise This week), Plan button. While waiting (40–80 s): "Planning… this can take
  a minute". Then the review list grouped Mon → Sun, a short AI note, **Add selected**,
  **Discard**. Clashing entries show a warning and start unticked. Below: "Recent plans"
  with Undo per batch.
- After adding: toast "Added N to My Week" with Undo, and open the My Week calendar.
- **Consent (first use):** "To plan your week, InkNest sends what you type and the titles
  and times of your My Week entries for this week and last week to InkNest's server and
  to NaraRouter (and the AI model provider behind it). InkNest's server does not store
  them. NaraRouter's and the provider's own data policies apply."

## Acceptance (v1)

1. Nothing is added to any calendar before Add selected.
2. Only ticked entries are added, with the user's edits.
3. Every added entry falls inside the chosen week.
4. Existing entries are never edited or deleted, except by Undo of the plan that added them.
5. Add twice / retry never duplicates entries.
6. Undo removes a plan's unchanged entries and keeps (and reports) changed ones.
7. "Same as last week, but …" reproduces last week's routine with the change applied.
8. Entries that clash with existing ones are marked and start unticked.
9. Switch off hides Plan my week everywhere on that device and sends nothing.
10. Works on Mac and S24; entries appear on both through AppFlowy sync.
11. AI failure or limit shows a clear message with Retry where it helps; nothing is added.

## Left to the builder

- Exact widget layout, file split, and state management (follow Organize's patterns).
- Prompt wording.
- How to read end times efficiently (per-row `getCell` is fine for ≤ 300 rows).
- Desktop settings placement of the switch (a row in the desktop AI settings page is fine).

## Calls made by Claude (please check)

- Shares the daily AI limit with Organize (one cap on the owner's bill).
- Separate on/off switch and separate consent from Organize (different data is sent).
- "My Week" is created in the user's current space on first use.
- All-day entries are supported; recurring events are not.
- One request → one draft; no back-and-forth chat in v1.
- Draft and recent plans are stored per device (a plan made on the S24 is undone on the S24).
- Desktop entry: sidebar button + calendar header; mobile entry: AI settings area + calendar header.
- Clashes are detected in the app (overlap with `busy` entries), not on the server.
- A row whose date can't be set after creation is deleted and counts as failed.
- Retrying after a partial Add continues with the entries still in the draft; entries
  already added stay in that plan's batch and are never added twice.
