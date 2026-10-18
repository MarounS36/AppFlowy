export type ChatMessage = { role: "system" | "user"; content: string };

export function parseModelOutput(text: string): unknown | null {
  const a = text.indexOf("{");
  const b = text.lastIndexOf("}");
  if (a < 0 || b < a) return null;
  try {
    return JSON.parse(text.slice(a, b + 1));
  } catch {
    return null;
  }
}

export type Profile = { uuid: string; email: string | null };
export type Usage = "ok" | "user_limit" | "global_limit";
/** Which step failed, logged on 502 only. Never carries content or messages. */
export type Cause =
  | "profile"
  | "allowlist"
  | "body"
  | "usage"
  | "ai"
  | "ai_output";
export type LogEntry = {
  user: string | null;
  status: number;
  ms: number;
  cause?: Cause;
};
export type Deps = {
  getProfile(token: string): Promise<Profile | null>;
  isInvited(email: string): Promise<boolean>;
  consume(userUuid: string): Promise<Usage>;
  complete(messages: ChatMessage[]): Promise<string>; // throws on provider failure
  log(entry: LogEntry): void;
  now(): number;
};

export type AiSpec<T, R> = {
  maxBytes: number;
  parse(raw: unknown): T | null;
  messages(req: T): ChatMessage[];
  validate(out: unknown, req: T): R | null;
};

export async function handleAi<T, R>(
  req: Request,
  deps: Deps,
  spec: AiSpec<T, R>,
): Promise<Response> {
  const start = deps.now();
  let user: string | null = null;
  const respond = (status: number, body: unknown, cause?: Cause) => {
    deps.log({ user, status, ms: deps.now() - start, ...(cause && { cause }) });
    return new Response(JSON.stringify(body), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  };
  const fail = (status: number, error: string, cause?: Cause) =>
    respond(status, { error }, cause);

  if (req.method !== "POST") return fail(405, "method_not_allowed");

  const token = /^Bearer (.+)$/.exec(req.headers.get("Authorization") ?? "")
    ?.[1];
  if (!token) return fail(401, "unauthorized");

  let step: Cause = "profile";
  try {
    const profile = await deps.getProfile(token);
    if (!profile) return fail(401, "unauthorized");
    user = profile.uuid;
    step = "allowlist";
    if (!profile.email || !(await deps.isInvited(profile.email))) {
      return fail(403, "not_invited");
    }

    step = "body";
    const text = await req.text();
    if (new TextEncoder().encode(text).length > spec.maxBytes) {
      return fail(413, "too_large");
    }
    let parsed;
    try {
      parsed = spec.parse(JSON.parse(text));
    } catch {
      parsed = null;
    }
    if (!parsed) return fail(400, "bad_request");

    step = "usage";
    const usage = await deps.consume(profile.uuid);
    if (usage !== "ok") return fail(429, usage);

    step = "ai";
    const out = parseModelOutput(await deps.complete(spec.messages(parsed)));
    const suggestion = spec.validate(out, parsed);
    if (!suggestion) return fail(502, "ai_failed", "ai_output");
    return respond(200, suggestion);
  } catch {
    return fail(502, "ai_failed", step);
  }
}
