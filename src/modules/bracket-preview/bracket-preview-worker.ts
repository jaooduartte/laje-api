import type { BracketPreviewWorkerDrainState } from "../../integrations/aws/dynamodb.client.js";
import type { SqsMessage } from "../../integrations/aws/sqs.client.js";
import { parseBracketPreviewQueueMessage } from "./bracket-preview-message.js";

export interface BracketPreviewQueueClient {
  receiveMessages(input: {
    waitTimeSeconds: number;
    visibilityTimeoutSeconds: number;
    maxNumberOfMessages?: number;
  }): Promise<SqsMessage[]>;
  deleteMessage(receiptHandle: string): Promise<void>;
  changeMessageVisibility(receiptHandle: string, visibilityTimeoutSeconds: number): Promise<void>;
}

export interface BracketPreviewDrainStore {
  getBracketPreviewWorkerDrainState(): Promise<BracketPreviewWorkerDrainState | null>;
  markBracketPreviewWorkerDrained(operationId: string): Promise<boolean>;
}

export interface BracketPreviewProcessor {
  process(jobId: string): Promise<unknown>;
  heartbeat(jobId: string): Promise<unknown>;
  recoverAndCleanup(): Promise<number>;
}

export interface BracketPreviewWorkerOptions {
  pollWaitSeconds: number;
  visibilityTimeoutSeconds: number;
  drainPollIntervalMs?: number;
  pause?: (milliseconds: number) => Promise<void>;
  logger?: Pick<Console, "error" | "log">;
}

const defaultPause = (milliseconds: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

export class BracketPreviewQueueWorker {
  private stopRequested = false;
  private workerPromise: Promise<void> | null = null;

  constructor(
    private readonly queue: BracketPreviewQueueClient,
    private readonly drainStore: BracketPreviewDrainStore,
    private readonly processor: BracketPreviewProcessor,
    private readonly options: BracketPreviewWorkerOptions,
  ) {}

  start(): void {
    if (this.workerPromise) return;

    this.stopRequested = false;
    this.workerPromise = this.workerLoop().catch((error: unknown) => {
      this.logger.error("Bracket preview SQS worker stopped unexpectedly.", error);
    });
  }

  async stop(): Promise<void> {
    this.stopRequested = true;
    await this.workerPromise;
  }

  private get logger(): Pick<Console, "error" | "log"> {
    return this.options.logger ?? console;
  }

  private get pause(): (milliseconds: number) => Promise<void> {
    return this.options.pause ?? defaultPause;
  }

  private async getDrainState(): Promise<BracketPreviewWorkerDrainState | null> {
    try {
      return await this.drainStore.getBracketPreviewWorkerDrainState();
    } catch (error) {
      this.logger.error("Unable to read the bracket preview worker drain state.", error);
      return null;
    }
  }

  private async markDrained(state: BracketPreviewWorkerDrainState): Promise<void> {
    try {
      await this.drainStore.markBracketPreviewWorkerDrained(state.operationId);
    } catch (error) {
      this.logger.error("Unable to confirm the bracket preview worker drain.", error);
    }
  }

  private async releaseMessages(messages: SqsMessage[]): Promise<void> {
    await Promise.all(
      messages.map(async (message) => {
        try {
          await this.queue.changeMessageVisibility(message.receiptHandle, 0);
        } catch (error) {
          this.logger.error(
            `Unable to release bracket preview SQS message (messageId=${message.messageId}).`,
            error,
          );
        }
      }),
    );
  }

  private async waitWhileDraining(state: BracketPreviewWorkerDrainState): Promise<boolean> {
    await this.markDrained(state);
    while (!this.stopRequested) {
      await this.pause(this.options.drainPollIntervalMs ?? 5_000);
      const nextState = await this.getDrainState();
      if (!nextState || (nextState.state !== "DRAINING" && nextState.state !== "DRAINED")) {
        return true;
      }
      if (nextState.state === "DRAINING") await this.markDrained(nextState);
    }
    return false;
  }

  private async processMessage(message: SqsMessage): Promise<void> {
    try {
      const payload = parseBracketPreviewQueueMessage(message.body);
      if (payload.type === "MAINTENANCE") {
        const requeued = await this.processor.recoverAndCleanup();
        this.logger.log(`Bracket preview maintenance completed; requeued=${requeued}.`);
      } else {
        const heartbeatIntervalMs = Math.max(
          15_000,
          Math.floor((this.options.visibilityTimeoutSeconds * 1_000) / 3),
        );
        const heartbeatTimer = setInterval(() => {
          void Promise.all([
            this.processor.heartbeat(payload.jobId),
            this.queue.changeMessageVisibility(
              message.receiptHandle,
              this.options.visibilityTimeoutSeconds,
            ),
          ]).catch((error: unknown) => {
            this.logger.error(
              `Bracket preview heartbeat failed (jobId=${payload.jobId}, messageId=${message.messageId}).`,
              error,
            );
          });
        }, heartbeatIntervalMs);

        try {
          await this.processor.process(payload.jobId);
        } finally {
          clearInterval(heartbeatTimer);
        }
      }
      await this.queue.deleteMessage(message.receiptHandle);
    } catch (error) {
      this.logger.error(
        `Bracket preview SQS message failed (messageId=${message.messageId}, receiveCount=${message.approximateReceiveCount}).`,
        error,
      );
    }
  }

  private async workerLoop(): Promise<void> {
    while (!this.stopRequested) {
      const drainState = await this.getDrainState();
      if (drainState && (drainState.state === "DRAINING" || drainState.state === "DRAINED")) {
        if (!(await this.waitWhileDraining(drainState))) return;
        continue;
      }

      const messages = await this.queue.receiveMessages({
        waitTimeSeconds: this.options.pollWaitSeconds,
        visibilityTimeoutSeconds: this.options.visibilityTimeoutSeconds,
        maxNumberOfMessages: 5,
      });

      if (this.stopRequested) {
        await this.releaseMessages(messages);
        return;
      }

      const afterReceiveDrainState = await this.getDrainState();
      if (
        afterReceiveDrainState &&
        (afterReceiveDrainState.state === "DRAINING" || afterReceiveDrainState.state === "DRAINED")
      ) {
        await this.releaseMessages(messages);
        if (!(await this.waitWhileDraining(afterReceiveDrainState))) return;
        continue;
      }

      for (let index = 0; index < messages.length; index += 1) {
        const message = messages[index]!;
        if (this.stopRequested) {
          await this.releaseMessages(messages.slice(index));
          return;
        }

        const currentDrainState = await this.getDrainState();
        if (
          currentDrainState &&
          (currentDrainState.state === "DRAINING" || currentDrainState.state === "DRAINED")
        ) {
          await this.releaseMessages(messages.slice(index));
          if (!(await this.waitWhileDraining(currentDrainState))) return;
          break;
        }

        await this.processMessage(message);
      }
    }
  }
}
