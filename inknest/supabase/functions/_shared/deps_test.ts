import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import { parseLimit, realDeps, toUsage } from "./deps.ts";

const ENV: Record<string, string> = {
  AF_CLOUD_URL: "https://af.test",
  NARA_BASE_URL: "https://nara.test/v1",
  NARA_MODEL: "agnes",
  NARA_API_KEY: "k",
  SUPABASE_URL: "https://sb.test",
  SUPABASE_SERVICE_ROLE_KEY: "s",
};
const env = (k: string) => ENV[k];

function stub(status: number, body: unknown) {
  const calls: { url: string; init?: RequestInit }[] = [];
  const fetchFn = ((url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init });
    return Promise.resolve(new Response(JSON.stringify(body), { status }));
  }) as typeof fetch;
  return { calls, fetchFn };
}

Deno.test("getProfile reads AppFlowy AppResponse", async () => {
  const { calls, fetchFn } = stub(200, {
    code: 0,
    data: { uuid: "u1", email: "A@B.C" },
  });
  const p = await realDeps(env, fetchFn).getProfile("tok");
  assertEquals(p, { uuid: "u1", email: "a@b.c" });
  assertEquals(calls[0].url, "https://af.test/api/user/profile");
  assertEquals(
    new Headers(calls[0].init?.headers).get("Authorization"),
    "Bearer tok",
  );
});

Deno.test("getProfile rejects error responses", async () => {
  assertEquals(
    await realDeps(env, stub(401, {}).fetchFn).getProfile("t"),
    null,
  );
  assertEquals(
    await realDeps(env, stub(200, { code: 1000, message: "x" }).fetchFn)
      .getProfile("t"),
    null,
  );
});

Deno.test("complete posts OpenAI-compatible request", async () => {
  const { calls, fetchFn } = stub(200, {
    choices: [{ message: { content: "hi" } }],
  });
  const messages = [{ role: "user" as const, content: "x" }];
  assertEquals(await realDeps(env, fetchFn).complete(messages), "hi");
  assertEquals(calls[0].url, "https://nara.test/v1/chat/completions");
  assertEquals(
    new Headers(calls[0].init?.headers).get("Authorization"),
    "Bearer k",
  );
  assertEquals(JSON.parse(String(calls[0].init?.body)), {
    model: "agnes",
    messages,
    temperature: 0,
  });
});

Deno.test("complete throws on non-200", async () => {
  await assertRejects(() => realDeps(env, stub(500, {}).fetchFn).complete([]));
});

Deno.test("parseLimit defaults and rejects bad values", () => {
  assertEquals(parseLimit(undefined, 50), 50);
  assertEquals(parseLimit("7", 50), 7);
  assertEquals(parseLimit("0", 50), 0);
  for (const bad of ["fifty", "", "-1", "1.5"]) {
    assertThrows(() => parseLimit(bad, 50));
  }
});

Deno.test("toUsage accepts only known values", () => {
  assertEquals(toUsage("user_limit"), "user_limit");
  assertThrows(() => toUsage(null));
  assertThrows(() => toUsage("nope"));
});
