import { handle } from "./handler.ts";
import { realDeps } from "./deps.ts";

Deno.serve((req) => handle(req, realDeps((k) => Deno.env.get(k))));
