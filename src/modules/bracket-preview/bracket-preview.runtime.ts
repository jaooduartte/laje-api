import { awsConfig } from "../../config/aws.config.js";
import { database } from "../../database/index.js";
import { AwsSqsClient } from "../../integrations/aws/sqs.client.js";
import { BracketPreviewService } from "./bracket-preview.service.js";

type QueueMessage = { type: "PROCESS_PREVIEW"; jobId: string } | { type: "MAINTENANCE" };

class BracketPreviewQueue {
  private readonly client: AwsSqsClient | null;

  constructor() {
    this.client =
      awsConfig.enabled && awsConfig.region && awsConfig.bracketPreviewQueueUrl
        ? new AwsSqsClient(awsConfig.region, awsConfig.bracketPreviewQueueUrl)
        : null;
  }

  async sendProcessJob(jobId: string, delaySeconds = 0): Promise<void> {
    if (!this.client) {
      throw new Error("Bracket preview SQS queue is not configured.");
    }
    await this.client.sendMessage(
      JSON.stringify({ type: "PROCESS_PREVIEW", jobId } satisfies QueueMessage),
      delaySeconds,
    );
  }

  getClient(): AwsSqsClient | null {
    return this.client;
  }
}

const queue = new BracketPreviewQueue();

export const bracketPreviewService = new BracketPreviewService(database, queue);

let workerRunning = false;
let stopRequested = false;

function parseMessage(body: string): QueueMessage {
  const parsed = JSON.parse(body) as Partial<QueueMessage>;
  if (parsed.type === "MAINTENANCE") return { type: "MAINTENANCE" };
  if (parsed.type === "PROCESS_PREVIEW" && typeof parsed.jobId === "string" && parsed.jobId) {
    return { type: "PROCESS_PREVIEW", jobId: parsed.jobId };
  }
  throw new Error("Unsupported bracket preview SQS message.");
}

async function workerLoop(): Promise<void> {
  const client = queue.getClient();
  if (!client) return;

  workerRunning = true;
  try {
    while (!stopRequested) {
      const messages = await client.receiveMessages({
        waitTimeSeconds: awsConfig.bracketPreviewPollWaitSeconds,
        visibilityTimeoutSeconds: awsConfig.bracketPreviewVisibilityTimeoutSeconds,
        maxNumberOfMessages: 5,
      });

      for (const message of messages) {
        if (stopRequested) break;
        try {
          const payload = parseMessage(message.body);
          if (payload.type === "MAINTENANCE") {
            const requeued = await bracketPreviewService.recoverAndCleanup();
            console.log(`Bracket preview maintenance completed; requeued=${requeued}.`);
          } else {
            await bracketPreviewService.process(payload.jobId);
          }
          await client.deleteMessage(message.receiptHandle);
        } catch (error) {
          console.error(
            `Bracket preview SQS message failed (messageId=${message.messageId}, receiveCount=${message.approximateReceiveCount}).`,
            error,
          );
        }
      }
    }
  } finally {
    workerRunning = false;
  }
}

export function startBracketPreviewWorker(): void {
  if (
    workerRunning ||
    !awsConfig.enabled ||
    !awsConfig.bracketPreviewWorkerEnabled ||
    !queue.getClient()
  ) {
    return;
  }

  stopRequested = false;
  void workerLoop().catch((error: unknown) => {
    workerRunning = false;
    console.error("Bracket preview SQS worker stopped unexpectedly.", error);
  });
}

export function stopBracketPreviewWorker(): void {
  stopRequested = true;
}
