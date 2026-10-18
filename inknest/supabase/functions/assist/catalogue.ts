import type { AssistContext } from "./core.ts";

export const MAX_ACTIONS = 80;
export const MAX_TITLE = 120;
const MAX_MD = 20000;
const MAX_CELL = 2000;
const FIELD_TYPES = [
  "text",
  "number",
  "date",
  "select",
  "multi_select",
  "checkbox",
];
const LAYOUTS = ["grid", "board", "calendar"];

export type Action = { type: string; [k: string]: unknown };

// field.add uses `field_type` because `type` is the action discriminator.
// Field order matters: board_id/database_id come before the ids scoped to them.
// "?" marks optional; `any` = at least one optional field must be present.
const SPEC: Record<string, { f: string; any?: boolean }> = {
  "calendar.add": { f: "title date start? end? all_day?" },
  "calendar.update": {
    f: "entry_id title? date? start? end? all_day?",
    any: true,
  },
  "calendar.remove": { f: "entry_id" },
  "board.create": { f: "temp_id name columns" },
  "board.column.add": { f: "board_id temp_id name" },
  "board.column.rename": { f: "board_id column_id name" },
  "board.column.remove": { f: "board_id column_id" },
  "board.card.add": { f: "board_id column_id temp_id title" },
  "board.card.update": { f: "board_id card_id title? column_id?", any: true },
  "board.card.remove": { f: "board_id card_id" },
  "page.create": { f: "temp_id parent_id name content" },
  "page.append": { f: "page_id content" },
  "page.rename": { f: "page_id name" },
  "page.move": { f: "page_id parent_id after_id?" },
  "page.duplicate": { f: "page_id temp_id" },
  "page.favorite": { f: "page_id on" },
  "page.delete": { f: "page_id" },
  "database.create": { f: "temp_id parent_id name layout fields" },
  "row.add": { f: "database_id temp_id cells" },
  "row.update": { f: "database_id row_id cells" },
  "row.remove": { f: "database_id row_id" },
  "field.add": { f: "database_id temp_id name field_type" },
  "field.rename": { f: "database_id field_id name" },
  "option.add": { f: "database_id field_id name" },
};
export const ACTION_TYPES: readonly string[] = Object.keys(SPEC);
export const describeAction = (t: string) =>
  `${t}(${SPEC[t].f.split(" ").join(", ")})`;

const ID_KIND: Record<string, string> = {
  entry_id: "entry",
  board_id: "board",
  column_id: "column",
  card_id: "card",
  page_id: "page",
  parent_id: "page",
  after_id: "page",
  database_id: "db",
  field_id: "field",
  row_id: "row",
};

type Db = {
  fields: Map<string, { type: string; writable: boolean }>;
  rows: Map<string, Record<string, string>>;
};
type State = {
  entries: Set<string>;
  boards: Map<string, { columns: Set<string>; cards: Set<string> }>;
  pages: Set<string>;
  dbs: Map<string, Db>;
  temps: Set<string>;
  week: string[];
};

const isObj = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);
const isStr = (v: unknown): v is string => typeof v === "string";
const line = (v: unknown): string | undefined => {
  if (!isStr(v)) return undefined;
  const t = v.trim();
  return t && !/[\r\n]/.test(t) && t.length <= MAX_TITLE ? t : undefined;
};
const time = (v: unknown) => isStr(v) && /^([01]\d|2[0-3]):[0-5]\d$/.test(v);

function initState(c: AssistContext): State {
  const d = new Date(c.week_start + "T00:00:00Z");
  const week = Array.from(
    { length: 7 },
    (_, i) => new Date(d.getTime() + i * 864e5).toISOString().slice(0, 10),
  );
  return {
    entries: new Set(c.calendar?.entries.map((e) => e.id)),
    boards: new Map((c.boards ?? []).map((b) => [b.id, {
      columns: new Set(b.columns?.map((x) => x.id)),
      cards: new Set(b.cards?.map((x) => x.id)),
    }])),
    pages: new Set(c.pages?.map((p) => p.id)),
    dbs: new Map((c.databases ?? []).map((db) => [db.id, {
      fields: new Map(
        db.fields.map((f) => [f.id, { type: f.type, writable: f.writable }]),
      ),
      rows: new Map((db.rows ?? []).map((r) => [r.id, r.cells])),
    }])),
    temps: new Set(),
    week,
  };
}

/** Returns the cleaned value, or undefined when invalid. */
function checkField(key: string, v: unknown, out: Action, st: State): unknown {
  const kind = ID_KIND[key];
  if (kind) {
    if (!isStr(v)) return undefined;
    const board = st.boards.get(out.board_id as string);
    const db = st.dbs.get(out.database_id as string);
    const ok = kind === "entry"
      ? st.entries.has(v)
      : kind === "board"
      ? st.boards.has(v)
      : kind === "column"
      ? board?.columns.has(v)
      : kind === "card"
      ? board?.cards.has(v)
      : kind === "page"
      ? st.pages.has(v)
      : kind === "db"
      ? st.dbs.has(v)
      : kind === "field"
      ? db?.fields.has(v)
      : db?.rows.has(v);
    return ok ? v : undefined;
  }
  switch (key) {
    case "temp_id":
      return isStr(v) && /^new:\d+$/.test(v) && !st.temps.has(v)
        ? v
        : undefined;
    case "title":
    case "name":
      return line(v);
    case "date":
      return isStr(v) && st.week.includes(v) ? v : undefined;
    case "start":
    case "end":
      return v === null || time(v) ? v : undefined;
    case "all_day":
    case "on":
      return typeof v === "boolean" ? v : undefined;
    case "content":
      return isStr(v) && v.trim() && v.length <= MAX_MD ? v : undefined;
    case "layout":
      return LAYOUTS.includes(v as string) ? v : undefined;
    case "field_type":
      return FIELD_TYPES.includes(v as string) ? v : undefined;
    case "columns":
      return Array.isArray(v) && v.length >= 1 && v.length <= 20 &&
          v.every((x) => line(x))
        ? v.map((x) => line(x))
        : undefined;
    case "fields":
      return Array.isArray(v) && v.length <= 30 &&
          v.every((x) =>
            isObj(x) && line(x.name) && FIELD_TYPES.includes(x.type as string)
          )
        ? v.map((x) => ({ name: line(x.name), type: x.type }))
        : undefined;
    case "cells": {
      if (!isObj(v) || Object.keys(v).length > 50) return undefined;
      const db = st.dbs.get(out.database_id as string);
      return Object.entries(v).every(([k, c]) =>
          isStr(c) && c.length <= MAX_CELL && db?.fields.get(k)?.writable
        )
        ? { ...v }
        : undefined;
    }
  }
  return undefined;
}

/** Type-specific rules that span several fields. */
function crossCheck(a: Action, st: State): boolean {
  const t = a.type;
  if (t === "calendar.add") {
    const timed = a.start != null || a.end != null;
    if (a.all_day === true) return !timed;
    return isStr(a.start) && isStr(a.end) && a.start < a.end;
  }
  if (t === "calendar.update") {
    return !(isStr(a.start) && isStr(a.end)) || a.start < a.end;
  }
  if (t === "page.move") {
    return a.page_id !== a.parent_id && a.page_id !== a.after_id;
  }
  if (t === "row.update") return Object.keys(a.cells as object).length > 0;
  const db = st.dbs.get(a.database_id as string);
  if (t === "row.remove") {
    const cells = db!.rows.get(a.row_id as string)!;
    return Object.entries(cells).every(([k, c]) =>
      !c || db!.fields.get(k)?.writable
    );
  }
  if (t === "option.add") {
    const f = db!.fields.get(a.field_id as string)!;
    return f.writable && (f.type === "select" || f.type === "multi_select");
  }
  return true;
}

/** Registers what a kept action creates so later actions can use its new:N id. */
function declare(a: Action, st: State) {
  const tmp = a.temp_id as string | undefined;
  if (!tmp) return;
  st.temps.add(tmp);
  const board = st.boards.get(a.board_id as string);
  const db = st.dbs.get(a.database_id as string);
  switch (a.type) {
    case "board.create":
      st.boards.set(tmp, { columns: new Set(), cards: new Set() });
      break;
    case "board.column.add":
      board!.columns.add(tmp);
      break;
    case "board.card.add":
      board!.cards.add(tmp);
      break;
    case "page.create":
    case "page.duplicate":
      st.pages.add(tmp);
      break;
    case "database.create":
      st.dbs.set(tmp, { fields: new Map(), rows: new Map() });
      break;
    case "row.add":
      db!.rows.set(tmp, {});
      break;
    case "field.add":
      db!.fields.set(tmp, { type: a.field_type as string, writable: true });
      break;
  }
}

function validateOne(
  raw: unknown,
  allowed: Set<string>,
  st: State,
): Action | null {
  if (
    !isObj(raw) || !isStr(raw.type) || !allowed.has(raw.type) || !SPEC[raw.type]
  ) return null;
  const { f, any } = SPEC[raw.type];
  const out: Action = { type: raw.type };
  let optional = 0;
  for (const spec of f.split(" ")) {
    const opt = spec.endsWith("?");
    const key = opt ? spec.slice(0, -1) : spec;
    if (opt && raw[key] === undefined) continue;
    const val = checkField(key, raw[key], out, st);
    if (val === undefined) return null;
    out[key] = val;
    if (opt) optional++;
  }
  if (any && optional === 0) return null;
  return crossCheck(out, st) ? out : null;
}

export function validateActionList(
  actions: unknown,
  allowedActions: string[],
  ctx: AssistContext,
): Action[] {
  if (!Array.isArray(actions)) return [];
  const allowed = new Set(allowedActions);
  const st = initState(ctx);
  const kept: Action[] = [];
  for (const raw of actions) {
    if (kept.length >= MAX_ACTIONS) break;
    const a = validateOne(raw, allowed, st);
    if (!a) continue;
    declare(a, st);
    kept.push(a);
  }
  return kept;
}
