import { createClient } from "jsr:@supabase/supabase-js@2";
import type { Deps, Usage } from "./handler.ts";

export function parseLimit(raw: string | undefined, dflt: number): number {
  if (raw === undefined) return dflt;
  if (!/^\d+$/.test(raw.trim())) throw new Error(`bad limit "${raw}"`);
  return Number(raw);
}

export function toUsage(data: unknown): Usage {
  if (data === "ok" || data === "user_limit" || data === "global_limit") {
    return data;
  }
  throw new Error("bad consume result");
}

export function realDeps(
  env: (key: string) => string | undefined,
  fetchFn: typeof fetch = fetch,
): Deps {
  const need = (k: string) => {
    const v = env(k);
    if (!v) throw new Error(`missing env ${k}`);
    return v;
  };
  const db = () =>
    createClient(need("SUPABASE_URL"), need("SUPABASE_SERVICE_ROLE_KEY"));

  return {
    async getProfile(token) {
      const res = await fetchFn(`${need("AF_CLOUD_URL")}/api/user/profile`, {
        headers: { Authorization: `Bearer ${token}` },
        signal: AbortSignal.timeout(10000),
      });
      if (!res.ok) return null;
      const body = await res.json();
      if (body?.code !== 0 || typeof body.data?.uuid !== "string") return null;
      const email = body.data.email;
      return {
        uuid: body.data.uuid,
        email: typeof email === "string" ? email.toLowerCase() : null,
      };
    },
    async isInvited(email) {
      const { data, error } = await db().from("organize_allowlist")
        .select("email").eq("email", email).maybeSingle();
      if (error) throw error;
      return data !== null;
    },
    async consume(userUuid) {
      const { data, error } = await db().rpc("organize_consume", {
        p_user: userUuid,
        p_user_limit: parseLimit(env("DAILY_LIMIT"), 50),
        p_global_limit: parseLimit(env("GLOBAL_DAILY_LIMIT"), 500),
      });
      if (error) throw error;
      return toUsage(data);
    },
    async complete(messages) {
      const res = await fetchFn(`${need("NARA_BASE_URL")}/chat/completions`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${need("NARA_API_KEY")}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: need("NARA_MODEL"),
          messages,
          temperature: 0,
        }),
        signal: AbortSignal.timeout(120000),
      });
      if (!res.ok) throw new Error(`provider ${res.status}`);
      const content = (await res.json())?.choices?.[0]?.message?.content;
      if (typeof content !== "string") throw new Error("empty completion");
      return content;
    },
    log: (entry) => console.log(JSON.stringify(entry)),
    now: Date.now,
  };
}
