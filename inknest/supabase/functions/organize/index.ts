import { handle } from "./handler.ts";
import { realDeps } from "../_shared/deps.ts";

Deno.serve((req) => handle(req, realDeps((k) => Deno.env.get(k))));
