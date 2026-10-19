import { type AiSpec, handleAi } from "../_shared/pipeline.ts";
import type { Deps } from "../_shared/pipeline.ts";
import {
  type AssistReply,
  type AssistRequest,
  buildAssistMessages,
  MAX_BODY_BYTES,
  parseAssistRequest,
  validateAssistReply,
} from "./core.ts";

export type {
  Cause,
  Deps,
  LogEntry,
  Profile,
  Usage,
} from "../_shared/pipeline.ts";

const assistSpec: AiSpec<AssistRequest, AssistReply> = {
  maxBytes: MAX_BODY_BYTES,
  parse: parseAssistRequest,
  messages: buildAssistMessages,
  validate: validateAssistReply,
};

export const handle = (req: Request, deps: Deps) =>
  handleAi(req, deps, assistSpec);
