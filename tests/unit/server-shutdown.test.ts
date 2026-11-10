import assert from "node:assert/strict";
import test from "node:test";

import { shutdownApiRuntime } from "../../src/server-shutdown.js";

function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

test("closes the database only after HTTP requests and active worker jobs drain", async () => {
  const httpClosed = deferred();
  const workerDrained = deferred();
  let databaseClosed = false;

  const shutdown = shutdownApiRuntime(
    () => httpClosed.promise,
    () => workerDrained.promise,
    async () => {
      databaseClosed = true;
    },
  );

  httpClosed.resolve();
  await Promise.resolve();
  assert.equal(databaseClosed, false);

  workerDrained.resolve();
  await shutdown;

  assert.equal(databaseClosed, true);
});
