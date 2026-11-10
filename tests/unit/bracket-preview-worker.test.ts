import assert from "node:assert/strict";
import test from "node:test";

import {
  BracketPreviewQueueWorker,
  type BracketPreviewDrainStore,
  type BracketPreviewProcessor,
  type BracketPreviewQueueClient,
} from "../../src/modules/bracket-preview/bracket-preview-worker.js";
import type { SqsMessage } from "../../src/integrations/aws/sqs.client.js";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function message(id: string): SqsMessage {
  return {
    messageId: id,
    receiptHandle: `receipt-${id}`,
    body: JSON.stringify({ type: "PROCESS_PREVIEW", jobId: id }),
    approximateReceiveCount: 1,
  };
}

function processor(overrides: Partial<BracketPreviewProcessor> = {}): BracketPreviewProcessor {
  return {
    process: async () => undefined,
    heartbeat: async () => undefined,
    recoverAndCleanup: async () => 0,
    ...overrides,
  };
}

function drainStore(
  getState: BracketPreviewDrainStore["getBracketPreviewWorkerDrainState"],
  markDrained: BracketPreviewDrainStore["markBracketPreviewWorkerDrained"],
): BracketPreviewDrainStore {
  return {
    getBracketPreviewWorkerDrainState: getState,
    markBracketPreviewWorkerDrained: markDrained,
  };
}

function quietLogger() {
  return { error: () => undefined, log: () => undefined };
}

test("waits for the active SQS job before completing worker shutdown", async () => {
  const processStarted = deferred<void>();
  const finishProcess = deferred<void>();
  const deleted: string[] = [];
  let received = false;
  const queue: BracketPreviewQueueClient = {
    async receiveMessages() {
      if (received) return [];
      received = true;
      return [message("active")];
    },
    async deleteMessage(receiptHandle) {
      deleted.push(receiptHandle);
    },
    async changeMessageVisibility() {},
  };
  const worker = new BracketPreviewQueueWorker(
    queue,
    drainStore(
      async () => null,
      async () => false,
    ),
    processor({
      async process() {
        processStarted.resolve();
        await finishProcess.promise;
      },
    }),
    { pollWaitSeconds: 20, visibilityTimeoutSeconds: 180, logger: quietLogger() },
  );

  worker.start();
  await processStarted.promise;
  let stopped = false;
  const shutdown = worker.stop().then(() => {
    stopped = true;
  });
  await Promise.resolve();

  assert.equal(stopped, false);
  assert.deepEqual(deleted, []);

  finishProcess.resolve();
  await shutdown;

  assert.equal(stopped, true);
  assert.deepEqual(deleted, ["receipt-active"]);
});

test("releases unstarted SQS messages and confirms the drain after the active job finishes", async () => {
  const processStarted = deferred<void>();
  const finishProcess = deferred<void>();
  const drainConfirmed = deferred<void>();
  const pauseStarted = deferred<void>();
  const messagesReleased: string[] = [];
  const messagesDeleted: string[] = [];
  let currentState: "RUNNING" | "DRAINING" | "DRAINED" = "RUNNING";
  let received = false;
  let wakeWorker: (() => void) | undefined;
  const queue: BracketPreviewQueueClient = {
    async receiveMessages() {
      if (received) return [];
      received = true;
      return [message("active"), message("queued")];
    },
    async deleteMessage(receiptHandle) {
      messagesDeleted.push(receiptHandle);
    },
    async changeMessageVisibility(receiptHandle, visibilityTimeoutSeconds) {
      assert.equal(visibilityTimeoutSeconds, 0);
      messagesReleased.push(receiptHandle);
    },
  };
  const worker = new BracketPreviewQueueWorker(
    queue,
    drainStore(
      async () =>
        currentState === "RUNNING" ? null : { state: currentState, operationId: "schedule-stop" },
      async (operationId) => {
        assert.equal(operationId, "schedule-stop");
        currentState = "DRAINED";
        drainConfirmed.resolve();
        return true;
      },
    ),
    processor({
      async process() {
        processStarted.resolve();
        await finishProcess.promise;
      },
    }),
    {
      pollWaitSeconds: 20,
      visibilityTimeoutSeconds: 180,
      pause: () =>
        new Promise<void>((resolve) => {
          wakeWorker = resolve;
          pauseStarted.resolve();
        }),
      logger: quietLogger(),
    },
  );

  worker.start();
  await processStarted.promise;
  currentState = "DRAINING";
  finishProcess.resolve();
  await drainConfirmed.promise;
  await pauseStarted.promise;

  const shutdown = worker.stop();
  wakeWorker?.();
  await shutdown;

  assert.deepEqual(messagesDeleted, ["receipt-active"]);
  assert.deepEqual(messagesReleased, ["receipt-queued"]);
});
