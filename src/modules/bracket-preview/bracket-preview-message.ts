export type QueueMessage =
  | { type: "PROCESS_PREVIEW"; jobId: string }
  | { type: "MAINTENANCE" };

// This is shared by the running worker and the non-destructive DLQ audit tool.
export function parseBracketPreviewQueueMessage(body: string): QueueMessage {
  const parsed = JSON.parse(body) as Partial<QueueMessage>;
  if (parsed.type === "MAINTENANCE") return { type: "MAINTENANCE" };
  if (parsed.type === "PROCESS_PREVIEW" && typeof parsed.jobId === "string" && parsed.jobId) {
    return { type: "PROCESS_PREVIEW", jobId: parsed.jobId };
  }
  throw new Error("Unsupported bracket preview SQS message.");
}

export type DlqMessageType = "MAINTENANCE" | "PROCESS_PREVIEW" | "INVALID";

export function classifyBracketPreviewDlqMessage(body: string): DlqMessageType {
  try {
    return parseBracketPreviewQueueMessage(body).type;
  } catch {
    return "INVALID";
  }
}
