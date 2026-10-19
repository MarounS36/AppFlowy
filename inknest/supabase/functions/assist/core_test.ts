import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  type Action,
  type AssistRequest,
  buildAssistMessages,
  parseAssistRequest,
  validateActions,
  validateAssistReply,
} from "./core.ts";
import { ACTION_TYPES } from "./catalogue.ts";

const context = {
  week_start: "2026-10-19",
  calendar: {
    id: "cal",
    entries: [{
      id: "e1",
      title: "Dentist",
      date: "2026-10-20",
      start: "16:00",
      end: "17:00",
      all_day: false,
    }],
  },
  boards: [{
    id: "b1",
    name: "Move",
    columns: [{ id: "c1", name: "To do" }],
    cards: [{ id: "k1", title: "Pack", column_id: "c1" }],
  }],
  pages: [{ id: "p1", name: "Trip", parent_id: "s1", layout: "document" }, {
    id: "s1",
    name: "Space",
    parent_id: "",
    layout: "space",
  }],
  databases: [{
    id: "d1",
    name: "Books",
    layout: "grid",
    fields: [
      { id: "f1", name: "Title", type: "text", writable: true },
      { id: "f2", name: "Link", type: "url", writable: false },
      { id: "f3", name: "Status", type: "select", writable: true },
    ],
    rows: [{ id: "r1", cells: { f1: "Dune" } as Record<string, string> }, {
      id: "r2",
      cells: { f1: "x", f2: "http://a" } as Record<string, string>,
    }],
  }],
};
const req: AssistRequest = {
  allowed_actions: [...ACTION_TYPES],
  messages: [{ role: "user", text: "hi" }],
  context,
};
const v = (a: unknown, r = req) => validateActions(a, r);
const types = (a: Action[]) => a.map((x) => x.type);

Deno.test("catalogue has 24 types", () =>
  assertEquals(ACTION_TYPES.length, 24));

Deno.test("drops unknown and wrong-kind ids", () => {
  const out = v([
    { type: "calendar.update", entry_id: "b1", title: "x" },
    { type: "calendar.update", entry_id: "e1", title: "x" },
    { type: "board.card.update", board_id: "b1", card_id: "k9", title: "x" },
    { type: "board.card.update", board_id: "b1", card_id: "k1", title: "x" },
    { type: "board.card.update", board_id: "b1", card_id: "k1" },
  ]);
  assertEquals(out.length, 2);
  assertEquals(out.map((a) => a.entry_id ?? a.card_id), ["e1", "k1"]);
});

Deno.test("temp ids must be bound earlier", () => {
  const col = {
    type: "board.column.add",
    board_id: "b1",
    temp_id: "new:1",
    name: "Doing",
  };
  const card = {
    type: "board.card.add",
    board_id: "b1",
    column_id: "new:1",
    temp_id: "new:2",
    title: "Box",
  };
  assertEquals(types(v([col, card])), ["board.column.add", "board.card.add"]);
  assertEquals(types(v([card, col])), ["board.column.add"]);
  assertEquals(types(v([col, { ...col }])), ["board.column.add"]);
  const mk = {
    type: "board.create",
    temp_id: "new:1",
    name: "N",
    columns: [{ temp_id: "new:5", name: "A" }, { temp_id: "new:6", name: "B" }],
  };
  assertEquals(
    types(
      v([mk, {
        type: "board.column.add",
        board_id: "new:1",
        temp_id: "new:2",
        name: "C",
      }]),
    ).length,
    2,
  );
});

Deno.test("calendar bounds", () => {
  const add = {
    type: "calendar.add",
    title: "T",
    date: "2026-10-21",
    start: "09:00",
    end: "10:00",
  };
  assertEquals(v([add]).length, 1);
  assertEquals(v([{ ...add, date: "2026-10-26" }]).length, 0);
  assertEquals(v([{ ...add, date: "2026-10-18" }]).length, 0);
  assertEquals(v([{ ...add, date: "2026-10-25" }]).length, 1);
  assertEquals(v([{ ...add, start: "18:00", end: "17:00" }]).length, 0);
  assertEquals(v([{ ...add, start: "9am" }]).length, 0);
  assertEquals(
    v([{
      type: "calendar.add",
      title: "T",
      date: "2026-10-21",
      start: null,
      end: null,
      all_day: true,
    }]).length,
    1,
  );
  assertEquals(
    v([{ type: "calendar.add", title: "T", date: "2026-10-21" }]).length,
    0,
  );
});

Deno.test("titles", () => {
  const t = (title: string) =>
    v([{ type: "calendar.add", title, date: "2026-10-21", all_day: true }])
      .length;
  assertEquals([t("a\nb"), t(""), t("x".repeat(121)), t("x".repeat(120))], [
    0,
    0,
    0,
    1,
  ]);
});

Deno.test("stage gating", () => {
  const a = {
    type: "page.create",
    temp_id: "new:1",
    parent_id: "s1",
    name: "N",
    content: "# hi",
  };
  assertEquals(v([a]).length, 1);
  assertEquals(v([a], { ...req, allowed_actions: ["calendar.add"] }).length, 0);
});

Deno.test("caps", () => {
  const a = {
    type: "calendar.add",
    title: "T",
    date: "2026-10-21",
    all_day: true,
  };
  assertEquals(v(Array.from({ length: 81 }, () => a)).length, 80);
  assertEquals(v("nope").length, 0);
});

Deno.test("strips unknown fields and bad shapes", () => {
  const out = v([
    { type: "calendar.remove", entry_id: "e1", extra: 1 },
    5,
    null,
    { type: "nope" },
  ]);
  assertEquals(out, [{ type: "calendar.remove", entry_id: "e1" }]);
});

Deno.test("pages", () => {
  assertEquals(
    types(v([
      { type: "page.append", page_id: "p1", content: "- a" },
      { type: "page.append", page_id: "zz", content: "- a" },
      { type: "page.move", page_id: "p1", parent_id: "p1" },
      { type: "page.move", page_id: "p1", parent_id: "s1", after_id: "p1" },
      { type: "page.move", page_id: "p1", parent_id: "s1" },
      { type: "page.favorite", page_id: "p1", on: true },
      { type: "page.favorite", page_id: "p1", on: "yes" },
      { type: "page.duplicate", page_id: "p1", temp_id: "new:1" },
      { type: "page.rename", page_id: "new:1", name: "Copy" },
    ])),
    [
      "page.append",
      "page.move",
      "page.favorite",
      "page.duplicate",
      "page.rename",
    ],
  );
});

Deno.test("databases, writable cells and row.remove", () => {
  const out = v([
    {
      type: "database.create",
      temp_id: "new:1",
      parent_id: "s1",
      name: "L",
      layout: "grid",
      fields: [{ temp_id: "new:20", name: "A", type: "text" }],
    },
    {
      type: "database.create",
      temp_id: "new:2",
      parent_id: "s1",
      name: "L",
      layout: "list",
      fields: [],
    },
    {
      type: "database.create",
      temp_id: "new:3",
      parent_id: "s1",
      name: "L",
      layout: "grid",
      fields: [{ temp_id: "new:21", name: "A", type: "url" }],
    },
    {
      type: "row.add",
      database_id: "d1",
      temp_id: "new:4",
      cells: { f1: "a" },
    },
    {
      type: "row.add",
      database_id: "d1",
      temp_id: "new:5",
      cells: { f2: "a" },
    },
    {
      type: "row.add",
      database_id: "d1",
      temp_id: "new:6",
      cells: { zz: "a" },
    },
    { type: "row.update", database_id: "d1", row_id: "r1", cells: { f1: "b" } },
    {
      type: "row.update",
      database_id: "d1",
      row_id: "new:4",
      cells: { f1: "b" },
    },
    { type: "row.remove", database_id: "d1", row_id: "r1" },
    { type: "row.remove", database_id: "d1", row_id: "r2" },
    {
      type: "field.add",
      database_id: "d1",
      temp_id: "new:7",
      name: "N",
      field_type: "multi_select",
    },
    { type: "option.add", database_id: "d1", field_id: "new:7", name: "o" },
    { type: "option.add", database_id: "d1", field_id: "f1", name: "o" },
    { type: "option.add", database_id: "d1", field_id: "f3", name: "o" },
    { type: "field.rename", database_id: "d1", field_id: "f2", name: "Url" },
    { type: "field.rename", database_id: "d9", field_id: "f2", name: "Url" },
  ]);
  assertEquals(
    out.map((a) => a.type + ":" + (a.temp_id ?? a.row_id ?? a.field_id ?? "")),
    [
      "database.create:new:1",
      "row.add:new:4",
      "row.update:r1",
      "row.update:new:4",
      "row.remove:r1",
      "field.add:new:7",
      "option.add:new:7",
      "option.add:f3",
      "field.rename:f2",
    ],
  );
});

Deno.test("timestamp metadata fields don't block row.remove", () => {
  const db = context.databases[0];
  const out = v([
    { type: "row.remove", database_id: "d1", row_id: "r3" },
    { type: "row.remove", database_id: "d1", row_id: "r4" },
  ], {
    ...req,
    context: {
      ...context,
      databases: [{
        ...db,
        fields: [
          ...db.fields,
          { id: "f4", name: "Created", type: "created_time", writable: false },
          {
            id: "f5",
            name: "Edited",
            type: "last_edited_time",
            writable: false,
          },
        ],
        rows: [
          { id: "r3", cells: { f1: "a", f4: "2026-10-19", f5: "2026-10-20" } },
          { id: "r4", cells: { f4: "2026-10-19", f2: "http://a" } },
        ],
      }],
    },
  });
  assertEquals(out.map((a) => a.row_id), ["r3"]);
});

Deno.test("parseAssistRequest rejects bad shapes", () => {
  assertEquals(
    parseAssistRequest({
      ...req,
      context: { ...context, week_start: undefined },
    }),
    null,
  );
  assertEquals(
    parseAssistRequest({ ...req, context: { ...context, week_start: "soon" } }),
    null,
  );
  assertEquals(parseAssistRequest({ ...req, messages: [] }), null);
  assertEquals(
    parseAssistRequest({ ...req, messages: [{ role: "system", text: "x" }] }),
    null,
  );
  assertEquals(
    parseAssistRequest({
      ...req,
      context: { ...context, boards: [{ id: 1 }] },
    }),
    null,
  );
  assertEquals(parseAssistRequest({ ...req, allowed_actions: "x" }), null);
  assertEquals(parseAssistRequest(null), null);
  assertEquals(parseAssistRequest(req), req);
});

Deno.test("buildAssistMessages encodes context as JSON data", () => {
  const r = { ...req, allowed_actions: ["calendar.add", "calendar.remove"] };
  const [sys, user] = buildAssistMessages(r);
  assertEquals(sys.role, "system");
  assertStringIncludes(sys.content, "calendar.add");
  assertStringIncludes(sys.content, "calendar.remove");
  assertEquals(sys.content.includes("board.create"), false);
  assertStringIncludes(user.content, JSON.stringify(context));
});

Deno.test("validateAssistReply", () => {
  assertEquals(validateAssistReply("x", req), null);
  assertEquals(validateAssistReply({ note: " hi ", actions: "bad" }, req), {
    note: "hi",
    actions: [],
  });
  assertEquals(
    validateAssistReply({
      note: 3,
      actions: [{ type: "calendar.remove", entry_id: "e1" }],
    }, req),
    { note: "", actions: [{ type: "calendar.remove", entry_id: "e1" }] },
  );
});

Deno.test("new board columns and database fields are declared", () => {
  const mk = {
    type: "board.create",
    temp_id: "new:1",
    name: "Move",
    columns: [{ temp_id: "new:2", name: "To do" }, {
      temp_id: "new:3",
      name: "Done",
    }],
  };
  const card = (b: string, c: string, t: string) => ({
    type: "board.card.add",
    board_id: b,
    column_id: c,
    temp_id: t,
    title: "Pack",
  });
  assertEquals(types(v([mk, card("new:1", "new:2", "new:4")])).length, 2);
  assertEquals(types(v([mk, card("b1", "new:3", "new:4")])), ["board.create"]);
  const dup = {
    ...mk,
    columns: [{ temp_id: "new:2", name: "A" }, { temp_id: "new:2", name: "B" }],
  };
  assertEquals(v([dup]).length, 0);
  assertEquals(v([{ ...mk, columns: ["A"] }]).length, 0);
  const db = {
    type: "database.create",
    temp_id: "new:5",
    parent_id: "s1",
    name: "L",
    layout: "grid",
    fields: [{ temp_id: "new:6", name: "A", type: "select" }],
  };
  assertEquals(
    types(v([
      db,
      {
        type: "row.add",
        database_id: "new:5",
        temp_id: "new:7",
        cells: { "new:6": "x" },
      },
      {
        type: "option.add",
        database_id: "new:5",
        field_id: "new:6",
        name: "o",
      },
      {
        type: "field.rename",
        database_id: "new:5",
        field_id: "new:6",
        name: "B",
      },
      {
        type: "row.add",
        database_id: "d1",
        temp_id: "new:8",
        cells: { "new:6": "x" },
      },
    ])),
    ["database.create", "row.add", "option.add", "field.rename"],
  );
});

Deno.test("removed items are no longer valid", () => {
  assertEquals(
    types(v([
      { type: "calendar.remove", entry_id: "e1" },
      { type: "calendar.update", entry_id: "e1", title: "x" },
      { type: "board.column.remove", board_id: "b1", column_id: "c1" },
      {
        type: "board.card.add",
        board_id: "b1",
        column_id: "c1",
        temp_id: "new:1",
        title: "x",
      },
      { type: "board.card.remove", board_id: "b1", card_id: "k1" },
      { type: "board.card.update", board_id: "b1", card_id: "k1", title: "x" },
      { type: "row.remove", database_id: "d1", row_id: "r1" },
      {
        type: "row.update",
        database_id: "d1",
        row_id: "r1",
        cells: { f1: "b" },
      },
      { type: "page.delete", page_id: "p1" },
      { type: "page.rename", page_id: "p1", name: "x" },
    ])),
    [
      "calendar.remove",
      "board.column.remove",
      "board.card.remove",
      "row.remove",
      "page.delete",
    ],
  );
});

Deno.test("prompt documents value shapes", () => {
  const [sys] = buildAssistMessages(req);
  assertStringIncludes(sys.content, '[{"temp_id": "new:N", "name": string}]');
  assertStringIncludes(sys.content, "grid|board|calendar");
  assertStringIncludes(sys.content, "multi_select");
});

Deno.test("prototype-named types and ids are inert", () => {
  const r = {
    ...req,
    allowed_actions: ["constructor", "__proto__", "calendar.remove"],
  };
  assertEquals(
    v(
      [{ type: "constructor" }, { type: "__proto__" }, { type: "toString" }],
      r,
    ),
    [],
  );
  assertEquals(v([{ type: "calendar.remove", entry_id: "__proto__" }], r), []);
  assertEquals(
    v([{
      type: "row.add",
      database_id: "d1",
      temp_id: "new:1",
      cells: JSON.parse('{"__proto__":"x"}'),
    }]),
    [],
  );
});
