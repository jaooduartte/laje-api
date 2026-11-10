import { awsConfig } from "../../config/aws.config.js";
import { database } from "../../database/index.js";
import { AwsDynamoDbClient } from "../../integrations/aws/dynamodb.client.js";
import { AwsSqsClient } from "../../integrations/aws/sqs.client.js";
import { BracketPreviewService } from "./bracket-preview.service.js";
import { BracketPreviewQueueWorker } from "./bracket-preview-worker.js";

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
    await this.client.sendMessage(JSON.stringify({ type: "PROCESS_PREVIEW", jobId }), delaySeconds);
  }

  getClient(): AwsSqsClient | null {
    return this.client;
  }
}

const queue = new BracketPreviewQueue();

export const bracketPreviewService = new BracketPreviewService(database, queue);

let worker: BracketPreviewQueueWorker | null = null;

export function startBracketPreviewWorker(): void {
  const client = queue.getClient();
  if (
    worker ||
    !awsConfig.enabled ||
    !awsConfig.bracketPreviewWorkerEnabled ||
    !client ||
    !awsConfig.region ||
    !awsConfig.bracketPreviewDrainTable
  ) {
    return;
  }

  worker = new BracketPreviewQueueWorker(
    client,
    new AwsDynamoDbClient(awsConfig.region, awsConfig.bracketPreviewDrainTable),
    bracketPreviewService,
    {
      pollWaitSeconds: awsConfig.bracketPreviewPollWaitSeconds,
      visibilityTimeoutSeconds: awsConfig.bracketPreviewVisibilityTimeoutSeconds,
    },
  );
  worker.start();
}

export async function stopBracketPreviewWorker(): Promise<void> {
  const currentWorker = worker;
  if (!currentWorker) return;
  await currentWorker.stop();
  worker = null;
}
