import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import {
  buildMessages,
  type OrganizeRequest,
  parseModelOutput,
  parseRequest,
  validateSuggestion,
} from "./core.ts";

const req: OrganizeRequest = {
  note: {
    id: "n1",
    title: "untitled",
    text: 'say "hi"\nbye',
    current_parent_id: "p0",
  },
  folders: [
    { id: "f1", path: "Work" },
    { id: "f2", path: "Home" },
    { id: "p0", path: "Inbox" },
  ],
  exclude: { titles: ["Bad"], folder_ids: ["f2"] },
};

Deno.test("parseRequest rejects missing fields", () => {
  assertEquals(parseRequest({ note: { id: "n" } }), null);
  assertEquals(parseRequest(req), req);
});

Deno.test("parseModelOutput strips fences and prose", () => {
  const t = 'Sure!\n```json\n{"title":"A","folder_id":"f1","reason":"r"}\n```';
  assertEquals(parseModelOutput(t), {
    title: "A",
    folder_id: "f1",
    reason: "r",
  });
  assertEquals(parseModelOutput("no json here"), null);
});

Deno.test("validateSuggestion keeps valid fields", () => {
  const s = { title: "Trip plan", folder_id: "f1", reason: "travel" };
  assertEquals(validateSuggestion(s, req), s);
});

Deno.test("validateSuggestion drops forged folder id", () => {
  assertEquals(
    validateSuggestion({ title: "T", folder_id: "evil", reason: "" }, req)
      ?.folder_id,
    null,
  );
});

Deno.test("validateSuggestion drops excluded and current-parent folders", () => {
  for (const id of ["f2", "p0"]) {
    assertEquals(
      validateSuggestion({ title: "T", folder_id: id, reason: "" }, req)
        ?.folder_id,
      null,
    );
  }
});

Deno.test("validateSuggestion drops bad titles", () => {
  for (const t of ["a\nb", "", "   ", "x".repeat(121), "untitled", "Bad"]) {
    assertEquals(
      validateSuggestion({ title: t, folder_id: null, reason: "" }, req)?.title,
      null,
      t,
    );
  }
  const ok = "x".repeat(120);
  assertEquals(
    validateSuggestion({ title: ok, folder_id: null, reason: "" }, req)?.title,
    ok,
  );
});

Deno.test("validateSuggestion returns null for non-object", () => {
  assertEquals(validateSuggestion("str", req), null);
  assertEquals(validateSuggestion({}, req), {
    title: null,
    folder_id: null,
    reason: "",
  });
});

Deno.test("buildMessages encodes note as JSON data", () => {
  const [sys, user] = buildMessages(req);
  assertEquals([sys.role, user.role], ["system", "user"]);
  assertStringIncludes(user.content, JSON.stringify(req.note.text));
  assertStringIncludes(sys.content, "untrusted");
  assertStringIncludes(sys.content, "folder_id");
  assertStringIncludes(sys.content, "null");
});
