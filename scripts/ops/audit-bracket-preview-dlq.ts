import { execFileSync } from "node:child_process";

import { classifyBracketPreviewDlqMessage } from "../../src/modules/bracket-preview/bracket-preview-message.js";

const REGION = "sa-east-1";
const ACCOUNT_ID = "549243453554";
const QUEUE_NAME = "laje-staging-bracket-preview-dlq";
const VISIBILITY_SECONDS = 300;

interface QueueAttributeResponse {
  Attributes?: Record<string, string>;
}

interface QueueMessagesResponse {
  Messages?: Array<{
    MessageId?: string;
    ReceiptHandle?: string;
    Body?: string;
    Attributes?: Record<string, string>;
  }>;
}

interface VisibilityBatchResult {
  Failed?: unknown[];
}

function awsJson<T>(args: string[]): T {
  const stdout = execFileSync("aws", [...args, "--region", REGION, "--output", "json"], {
    encoding: "utf8",
    timeout: 60_000,
    maxBuffer: 2 * 1024 * 1024,
  });
  return JSON.parse(stdout) as T;
}

function audit(): void {
  // The account and queue are intentionally fixed: this script cannot audit production by mistake.
  const identity = awsJson<{ Account: string }>(["sts", "get-caller-identity"]);
  if (identity.Account !== ACCOUNT_ID) {
    throw new Error("AWS account mismatch: expected the LAJE staging account.");
  }

  const queueUrl = "https://sqs." + REGION + ".amazonaws.com/" + ACCOUNT_ID + "/" + QUEUE_NAME;
  const initial = awsJson<QueueAttributeResponse>([
    "sqs",
    "get-queue-attributes",
    "--queue-url",
    queueUrl,
    "--attribute-names",
    "ApproximateNumberOfMessages",
    "ApproximateNumberOfMessagesNotVisible",
  ]).Attributes;
  const expectedVisible = Number(initial?.ApproximateNumberOfMessages ?? "0");
  const alreadyInFlight = Number(initial?.ApproximateNumberOfMessagesNotVisible ?? "0");
  if (!Number.isSafeInteger(expectedVisible) || !Number.isSafeInteger(alreadyInFlight)) {
    throw new Error("SQS returned an invalid message count.");
  }
  if (alreadyInFlight !== 0) {
    throw new Error("DLQ contains in-flight messages; retry when visibility clears.");
  }

  const seen = new Set<string>();
  const types: Record<"MAINTENANCE" | "PROCESS_PREVIEW" | "INVALID", number> = {
    MAINTENANCE: 0,
    PROCESS_PREVIEW: 0,
    INVALID: 0,
  };
  const receiptHandles: string[] = [];
  const sentDates: number[] = [];
  let emptyPolls = 0;
  let polls = 0;
  let failedRelease = 0;

  try {
    const maxPolls = Math.min(300, Math.max(60, expectedVisible * 2));
    while (seen.size < expectedVisible && emptyPolls < 6 && polls < maxPolls) {
      const batch = awsJson<QueueMessagesResponse>([
        "sqs",
        "receive-message",
        "--queue-url",
        queueUrl,
        "--max-number-of-messages",
        "10",
        "--visibility-timeout",
        String(VISIBILITY_SECONDS),
        "--wait-time-seconds",
        "0",
        "--message-system-attribute-names",
        "SentTimestamp",
      ]);
      polls += 1;
      const messages = batch.Messages ?? [];
      if (messages.length === 0) {
        emptyPolls += 1;
        continue;
      }
      emptyPolls = 0;
      for (const message of messages) {
        if (!message.MessageId || !message.ReceiptHandle) {
          types.INVALID += 1;
          continue;
        }
        receiptHandles.push(message.ReceiptHandle);
        if (seen.has(message.MessageId)) continue;
        seen.add(message.MessageId);
        const type = classifyBracketPreviewDlqMessage(message.Body ?? "");
        types[type] += 1;
        const timestamp = Number(message.Attributes?.SentTimestamp);
        if (Number.isFinite(timestamp) && timestamp > 0) sentDates.push(timestamp);
      }
    }
  } finally {
    // Never delete or redrive: release visibility even if parsing or AWS calls fail.
    for (let i = 0; i < receiptHandles.length; i += 10) {
      const entries = receiptHandles.slice(i, i + 10).map((handle, index) => ({
        Id: String(index),
        ReceiptHandle: handle,
        VisibilityTimeout: 0,
      }));
      try {
        const result = awsJson<VisibilityBatchResult>([
          "sqs",
          "change-message-visibility-batch",
          "--queue-url",
          queueUrl,
          "--entries",
          JSON.stringify(entries),
        ]);
        failedRelease += result.Failed?.length ?? 0;
      } catch {
        failedRelease += entries.length;
      }
    }
  }

  const report = {
    queue: QUEUE_NAME,
    expectedVisibleBefore: expectedVisible,
    auditedUniqueMessages: seen.size,
    messageTypes: types,
    firstSentAt: sentDates.length ? new Date(Math.min(...sentDates)).toISOString() : null,
    lastSentAt: sentDates.length ? new Date(Math.max(...sentDates)).toISOString() : null,
    receiveCalls: polls,
    failedVisibilityReleases: failedRelease,
    deletedMessages: 0,
    redrivenMessages: 0,
  };
  console.log(JSON.stringify(report, null, 2));
  if (failedRelease > 0 || seen.size !== expectedVisible || types.INVALID > 0) {
    process.exitCode = 2;
  }
}

try {
  audit();
} catch (error: unknown) {
  console.error("DLQ audit failed:", error instanceof Error ? error.message : "Unknown error");
  process.exitCode = 1;
}
