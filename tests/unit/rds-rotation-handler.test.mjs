import assert from "node:assert/strict";
import test from "node:test";
import {
  handleRotation,
  isExpectedRotationEvent,
} from "../../infra/aws/lambda/rds-rotation-handler.mjs";
const config = {
  accountId: "549243453554",
  region: "sa-east-1",
  secretArn: "arn:aws:secretsmanager:sa-east-1:549243453554:secret:rds!db-test-ABC",
  lockTable: "laje-staging-rds-rotation-lock",
  cluster: "laje-staging-api",
  service: "laje-staging-api",
  databaseHealthUrl: "https://example.invalid/database",
  publicSettingsUrl: "https://example.invalid/settings",
};
const event = {
  source: "aws.secretsmanager",
  "detail-type": "Secret Label Updated",
  account: config.accountId,
  region: config.region,
  resources: [config.secretArn],
  detail: { labelUpdated: "AWSCURRENT", versionId: "v2" },
};
const secret = {
  ARN: config.secretArn,
  LastChangedDate: new Date("2026-10-12T03:09:15Z"),
  VersionIdsToStages: { v2: ["AWSCURRENT"] },
};
function mocks({ suspended = false, fresh = false, failedHealth = false, locked = false } = {}) {
  let restarted = false;
  const calls = [];
  const deps = {
    async acquireLock() { calls.push("lock"); return !locked; },
    async releaseLock() { calls.push("unlock"); },
    async describeSecret() {
      calls.push("secret");
      return secret;
    },
    async describeService() {
      calls.push("service");
      return {
        serviceName: config.service,
        status: "ACTIVE",
        desiredCount: suspended ? 0 : 1,
        runningCount: suspended ? 0 : 1,
        deployments: [{ rolloutState: "COMPLETED" }],
      };
    },
    async listTasks() {
      return ["task"];
    },
    async describeTasks() {
      return [
        {
          lastStatus: "RUNNING",
          healthStatus: "HEALTHY",
          startedAt:
            fresh || restarted
              ? new Date("2026-10-13T01:00:00Z")
              : new Date("2026-10-10T00:00:00Z"),
        },
      ];
    },
    async forceNewDeployment() {
      calls.push("force");
      restarted = true;
    },
    async waitForStable() {
      calls.push("wait");
    },
    async checkPublicHealth() {
      calls.push("health");
      if (failedHealth) throw new Error("bad health");
    },
    async sleep() {},
  };
  return { deps, calls };
}
test("requires exact account, region, ARN, current label", () => {
  assert.equal(isExpectedRotationEvent(event, config), true);
  for (const sample of [
    { ...event, account: "other" },
    { ...event, region: "us-east-1" },
    { ...event, resources: ["other"] },
    { ...event, detail: { labelUpdated: "AWSPENDING", versionId: "v2" } },
  ])
    assert.equal(isExpectedRotationEvent(sample, config), false);
});
test("ignores unrelated/stale versions and suspended staging", async () => {
  const m = mocks();
  assert.equal(
    (await handleRotation({ ...event, region: "us-east-1" }, m.deps, config)).outcome,
    "ignored",
  );
  assert.equal(m.calls.length, 0);
  const n = mocks({ suspended: true });
  assert.equal((await handleRotation(event, n.deps, config)).reason, "staging-suspended");
  assert.equal(n.calls.includes("force"), false);
  const s = mocks();
  s.deps.describeSecret = async () => ({ ...secret, VersionIdsToStages: { v2: ["AWSPREVIOUS"] } });
  assert.equal((await handleRotation(event, s.deps, config)).reason, "not-current-version");
});
test("restarts once and verifies public and database health", async () => {
  const x = mocks();
  assert.equal((await handleRotation(event, x.deps, config)).outcome, "deployed");
  assert.equal(x.calls.filter((x) => x === "force").length, 1);
  assert.equal(x.calls.filter((x) => x === "health").length, 2);
});
test("deduplicates fresh task and fails visibly if post-deploy health fails", async () => {
  const x = mocks({ fresh: true });
  assert.equal((await handleRotation(event, x.deps, config)).reason, "already-updated");
  assert.equal(x.calls.includes("force"), false);
  const y = mocks({ failedHealth: true });
  await assert.rejects(handleRotation(event, y.deps, config), /bad health/);
});

test("serializes concurrent handler invocations without reserving account concurrency", async () => {
  const busy = mocks({ locked: true });
  await assert.rejects(handleRotation(event, busy.deps, config), /already in progress/);
  assert.equal(busy.calls.includes("force"), false);
  assert.equal(busy.calls.includes("unlock"), false);
  const single = mocks();
  await handleRotation(event, single.deps, config);
  assert.equal(single.calls.filter((x) => x === "lock").length, 1);
  assert.equal(single.calls.filter((x) => x === "unlock").length, 1);
});
test("releases the distributed lock even when post-deployment health checks fail", async () => {
  const broken = mocks({ failedHealth: true });
  await assert.rejects(handleRotation(event, broken.deps, config), /bad health/);
  assert.equal(broken.calls.filter((x) => x === "unlock").length, 1);
});
