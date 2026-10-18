import { type AiSpec, handleAi } from "../_shared/pipeline.ts";
import type { Deps } from "../_shared/pipeline.ts";
import {
  buildMessages,
  MAX_BODY_BYTES,
  type OrganizeRequest,
  parseRequest,
  type Suggestion,
  validateSuggestion,
} from "./core.ts";

export type {
  Cause,
  Deps,
  LogEntry,
  Profile,
  Usage,
} from "../_shared/pipeline.ts";

const organizeSpec: AiSpec<OrganizeRequest, Suggestion> = {
  maxBytes: MAX_BODY_BYTES,
  parse: parseRequest,
  messages: buildMessages,
  validate: validateSuggestion,
};

export const handle = (req: Request, deps: Deps) =>
  handleAi(req, deps, organizeSpec);
