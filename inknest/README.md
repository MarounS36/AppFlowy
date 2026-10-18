# InkNest backend

Supabase Edge Function `organize` suggests a note title and folder.
Status: not deployed yet (needs the owner's Supabase project and NaraRouter key).

## Deploy (run in `inknest/`)

```bash
supabase login
supabase link --project-ref <project-ref>
supabase db push
supabase secrets set NARA_API_KEY=<key> NARA_BASE_URL=<nara base url> NARA_MODEL=<agnes alias> \
  AF_CLOUD_URL=https://beta.appflowy.cloud DAILY_LIMIT=50 GLOBAL_DAILY_LIMIT=500
supabase functions deploy organize --no-verify-jwt
```

URL: `https://<project-ref>.supabase.co/functions/v1/organize`
(callers send an AppFlowy token, so JWT verification is off).

Secrets: `NARA_API_KEY`, `NARA_BASE_URL`, `NARA_MODEL`, `AF_CLOUD_URL`,
`DAILY_LIMIT` (default 50), `GLOBAL_DAILY_LIMIT` (default 500).
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided by Supabase.

## Invite a user

In the Supabase SQL editor:

```sql
insert into organize_allowlist values (lower('<sign-in email>'));
```

## Change limits

Re-run `supabase secrets set DAILY_LIMIT=<n> GLOBAL_DAILY_LIMIT=<n>`.

## Test

```bash
deno test --allow-env inknest/supabase/functions/organize/
```

Smoke after deploy: `curl -s -X GET <url>` returns 405 `method_not_allowed`;
`curl -s -X POST <url> -d '{}'` returns 401 `unauthorized`.
