import assert from "node:assert/strict";
import test from "node:test";

import { runWithAwsInfrastructure } from "../../scripts/aws-infrastructure-session.mjs";

test("cleans up the resource lease after a successful session", async () => {
  const lease = { ecs: true, rds: false };
  let receivedLease;
  const result = await runWithAwsInfrastructure(
    async () => lease,
    async () => "finished",
    async (resourcesStartedBySession) => {
      receivedLease = resourcesStartedBySession;
    },
  );

  assert.equal(result, "finished");
  assert.equal(receivedLease, lease);
});

test("cleans up the resource lease when the session fails", async () => {
  const lease = { ecs: false, rds: true };
  const sessionError = new Error("SSM session ended unexpectedly");
  let receivedLease;

  await assert.rejects(
    runWithAwsInfrastructure(
      async () => lease,
      async () => {
        throw sessionError;
      },
      async (resourcesStartedBySession) => {
        receivedLease = resourcesStartedBySession;
      },
    ),
    (error) => error === sessionError,
  );
  assert.equal(receivedLease, lease);
});

test("preserves both session and cleanup errors", async () => {
  const sessionError = new Error("SSM session ended unexpectedly");
  const cleanupError = new Error("RDS could not be stopped");

  await assert.rejects(
    runWithAwsInfrastructure(
      async () => ({ ecs: true, rds: true }),
      async () => {
        throw sessionError;
      },
      async () => {
        throw cleanupError;
      },
    ),
    (error) => {
      assert.ok(error instanceof AggregateError);
      assert.deepEqual(error.errors, [sessionError, cleanupError]);
      return true;
    },
  );
});
