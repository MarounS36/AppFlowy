import {
  buildMessages,
  type ChatMessage,
  MAX_BODY_BYTES,
  parseModelOutput,
  parseRequest,
  validateSuggestion,
} from "./core.ts";

export type Profile = { uuid: string; email: string | null };
export type Usage = "ok" | "user_limit" | "global_limit";
export type Deps = {
  getProfile(token: string): Promise<Profile | null>;
  isInvited(email: string): Promise<boolean>;
  consume(userUuid: string): Promise<Usage>;
  complete(messages: ChatMessage[]): Promise<string>; // throws on provider failure
  log(entry: { user: string | null; status: number; ms: number }): void;
  now(): number;
};

export async function handle(req: Request, deps: Deps): Promise<Response> {
  const start = deps.now();
  let user: string | null = null;
  const respond = (status: number, body: unknown) => {
    deps.log({ user, status, ms: deps.now() - start });
    return new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  };
  const fail = (status: number, error: string) => respond(status, { error });

  if (req.method !== "POST") return fail(405, "method_not_allowed");

  const token = /^Bearer (.+)$/.exec(req.headers.get("Authorization") ?? "")
    ?.[1];
  if (!token) return fail(401, "unauthorized");

  try {
    const profile = await deps.getProfile(token);
    if (!profile) return fail(401, "unauthorized");
    user = profile.uuid;
    if (!profile.email || !(await deps.isInvited(profile.email))) {
      return fail(403, "not_invited");
    }

    const text = await req.text();
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) {
      return fail(413, "too_large");
    }
    let parsed;
    try {
      parsed = parseRequest(JSON.parse(text));
    } catch {
      parsed = null;
    }
    if (!parsed) return fail(400, "bad_request");

    const usage = await deps.consume(profile.uuid);
    if (usage !== "ok") return fail(429, usage);

    const out = parseModelOutput(await deps.complete(buildMessages(parsed)));
    const suggestion = validateSuggestion(out, parsed);
    if (!suggestion) return fail(502, "ai_failed");
    return respond(200, suggestion);
  } catch {
    return fail(502, "ai_failed");
  }
}
