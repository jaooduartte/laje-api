import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, delimiter } from "node:path";
import test, { after } from "node:test";

const temporaryDirectory = await mkdtemp(join(tmpdir(), "laje-aws-infrastructure-test-"));
const binaryDirectory = join(temporaryDirectory, "bin");
const stateFile = join(temporaryDirectory, "state.json");
await import("node:fs/promises").then(({ mkdir }) => mkdir(binaryDirectory));

const originalPath = process.env.PATH;
const originalEnvironment = new Map(
  [
    "AWS_EXPECTED_ACCOUNT_ID",
    "AWS_ECS_CLUSTER",
    "AWS_ECS_SERVICE",
    "AWS_OPERATION_LOCK_TABLE",
    "AWS_RDS_INSTANCE_IDENTIFIER",
  ].map((name) => [name, process.env[name]]),
);

process.env.PATH = `${binaryDirectory}${delimiter}${originalPath ?? ""}`;
process.env.AWS_EXPECTED_ACCOUNT_ID = "111111111111";
process.env.AWS_ECS_CLUSTER = "test-cluster";
process.env.AWS_ECS_SERVICE = "test-service";
process.env.AWS_OPERATION_LOCK_TABLE = "test-rds-rotation-lock";
process.env.AWS_RDS_INSTANCE_IDENTIFIER = "test-database";
process.env.AWS_FIXTURE_STATE_FILE = stateFile;

const fakeAws = join(temporaryDirectory, "fake-aws.mjs");
await writeFile(
  fakeAws,
  `import { readFileSync, writeFileSync } from "node:fs";

const stateFile = process.env.AWS_FIXTURE_STATE_FILE;
const state = JSON.parse(readFileSync(stateFile, "utf8"));
const argumentsList = process.argv.slice(2);
state.items ??= {};

function saveState() {
  writeFileSync(stateFile, JSON.stringify(state));
}

state.calls.push(argumentsList);
saveState();

if (argumentsList[0] === "sts") {
  process.stdout.write(JSON.stringify({ Account: state.account }));
} else if (argumentsList[0] === "rds" && argumentsList[1] === "describe-db-instances") {
  process.stdout.write(JSON.stringify({ DBInstances: [{ DBInstanceStatus: state.rdsStatus }] }));
} else if (argumentsList[0] === "rds" && argumentsList[1] === "start-db-instance") {
  state.rdsStatus = "available";
  saveState();
  process.stdout.write(JSON.stringify({}));
} else if (argumentsList[0] === "rds" && argumentsList[1] === "stop-db-instance") {
  state.rdsStatus = "stopped";
  saveState();
  process.stdout.write(JSON.stringify({}));
} else if (argumentsList[0] === "rds" && argumentsList[1] === "wait") {
  process.stdout.write("");
} else if (argumentsList[0] === "ecs" && argumentsList[1] === "describe-services") {
  process.stdout.write(
    JSON.stringify(
      state.ecsExists
        ? { services: [{ status: "ACTIVE", desiredCount: state.ecsDesiredCount }] }
        : { services: [], failures: [{ reason: "MISSING" }] },
    ),
  );
} else if (argumentsList[0] === "ecs" && argumentsList[1] === "update-service") {
  const desiredCountIndex = argumentsList.indexOf("--desired-count");
  state.ecsDesiredCount = Number(argumentsList[desiredCountIndex + 1]);
  saveState();
  process.stdout.write(JSON.stringify({}));
} else if (argumentsList[0] === "ecs" && argumentsList[1] === "list-tasks") {
  process.stdout.write(
    JSON.stringify({ taskArns: state.ecsDesiredCount > 0 ? ["arn:aws:ecs:sa-east-1:111111111111:task/test-cluster/task-1"] : [] }),
  );
} else if (argumentsList[0] === "ecs" && argumentsList[1] === "describe-tasks") {
  const tasksIndex = argumentsList.indexOf("--tasks");
  const nextOptionIndex = argumentsList.findIndex(
    (value, index) => index > tasksIndex && value.startsWith("--"),
  );
  const taskArns = argumentsList.slice(
    tasksIndex + 1,
    nextOptionIndex < 0 ? undefined : nextOptionIndex,
  );
  const describeTasksAttempt = state.describeTasksAttempts ?? 0;
  const taskIsStopping =
    state.taskDescribeAlwaysStopping === true ||
    describeTasksAttempt < (state.taskDescribePendingResponses ?? 0);
  state.describeTasksAttempts = describeTasksAttempt + 1;
  saveState();
  process.stdout.write(
    JSON.stringify({
      tasks: taskArns.map((taskArn) => ({
        taskArn,
        lastStatus: taskIsStopping ? "STOPPING" : "STOPPED",
        containers: [
          {
            name: "api",
            ...(taskIsStopping ? {} : { exitCode: state.taskExitCode ?? 0 }),
          },
        ],
      })),
    }),
  );
} else if (argumentsList[0] === "ecs" && argumentsList[1] === "wait") {
  process.stdout.write("");
} else if (argumentsList[0] === "dynamodb" && argumentsList[1] === "list-tables") {
  process.stdout.write(JSON.stringify({ TableNames: ["test-rds-rotation-lock"] }));
} else if (argumentsList[0] === "dynamodb" && argumentsList[1] === "put-item") {
  const itemIndex = argumentsList.indexOf("--item");
  const item = JSON.parse(argumentsList[itemIndex + 1]);
  const lockId = item.LockId.S;
  const conditionIndex = argumentsList.indexOf("--condition-expression");
  if (
    conditionIndex >= 0 &&
    argumentsList[conditionIndex + 1].includes("attribute_not_exists(LockId)") &&
    Number(state.items[lockId]?.ExpiresAt?.N ?? 0) >= Math.floor(Date.now() / 1000)
  ) {
    process.stderr.write("ConditionalCheckFailedException");
    process.exitCode = 1;
  } else {
    if (lockId === "bracket-preview-worker") item.State = { S: "DRAINED" };
    state.items[lockId] = item;
    saveState();
    process.stdout.write("");
  }
} else if (argumentsList[0] === "dynamodb" && argumentsList[1] === "get-item") {
  const keyIndex = argumentsList.indexOf("--key");
  const key = JSON.parse(argumentsList[keyIndex + 1]);
  process.stdout.write(JSON.stringify({ Item: state.items[key.LockId.S] }));
} else if (argumentsList[0] === "dynamodb" && argumentsList[1] === "update-item") {
  const keyIndex = argumentsList.indexOf("--key");
  const key = JSON.parse(argumentsList[keyIndex + 1]);
  const valuesIndex = argumentsList.indexOf("--expression-attribute-values");
  const values = JSON.parse(argumentsList[valuesIndex + 1]);
  const item = state.items[key.LockId.S] ?? { LockId: key.LockId };
  item.ExpiresAt = values[":expiresAt"] ?? item.ExpiresAt;
  state.items[key.LockId.S] = item;
  saveState();
  process.stdout.write("");
} else if (argumentsList[0] === "dynamodb" && argumentsList[1] === "delete-item") {
  const keyIndex = argumentsList.indexOf("--key");
  const key = JSON.parse(argumentsList[keyIndex + 1]);
  const lockId = key.LockId.S;
  const conditionIndex = argumentsList.indexOf("--condition-expression");
  if (conditionIndex >= 0) {
    const valuesIndex = argumentsList.indexOf("--expression-attribute-values");
    const values = JSON.parse(argumentsList[valuesIndex + 1]);
    const current = state.items[lockId];
    const expectedHolder = values[":holder"]?.S;
    const expectedOperation = values[":operationId"]?.S;
    if (
      (expectedHolder && current?.Holder?.S !== expectedHolder) ||
      (expectedOperation && current?.OperationId?.S !== expectedOperation)
    ) {
      process.stderr.write("ConditionalCheckFailedException");
      process.exitCode = 1;
    } else {
      delete state.items[lockId];
      saveState();
      process.stdout.write("");
    }
  } else {
    delete state.items[lockId];
    saveState();
    process.stdout.write("");
  }
} else {
  process.stderr.write("Unexpected AWS CLI arguments: " + argumentsList.join(" "));
  process.exitCode = 1;
}
`,
);
const awsExecutable = join(binaryDirectory, "aws");
await writeFile(awsExecutable, `#!/bin/sh\nexec node "${fakeAws}" "$@"\n`);
await chmod(awsExecutable, 0o755);

const { renewManualOverride, startAwsInfrastructure, stopAwsInfrastructure } =
  await import("../../scripts/aws-infrastructure.mjs");
const { acquireAwsOperationLock } = await import("../../scripts/aws-operation-lock.mjs");

async function setState(state) {
  await writeFile(stateFile, JSON.stringify({ account: "111111111111", calls: [], ...state }));
}

async function getState() {
  return JSON.parse(await readFile(stateFile, "utf8"));
}

async function withImmediateEcsShutdownPolling(action) {
  const originalSetTimeout = globalThis.setTimeout;
  globalThis.setTimeout = (callback, delay, ...argumentsList) =>
    originalSetTimeout(callback, delay === 15_000 ? 0 : delay, ...argumentsList);

  try {
    return await action();
  } finally {
    globalThis.setTimeout = originalSetTimeout;
  }
}

after(async () => {
  if (originalPath === undefined) delete process.env.PATH;
  else process.env.PATH = originalPath;
  for (const [name, value] of originalEnvironment) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  delete process.env.AWS_FIXTURE_STATE_FILE;
  await rm(temporaryDirectory, { recursive: true, force: true });
});

test("preserves RDS and ECS resources that were already active", async () => {
  await setState({ rdsStatus: "available", ecsDesiredCount: 2, ecsExists: true });

  const resourcesStartedBySession = await startAwsInfrastructure();
  await stopAwsInfrastructure(resourcesStartedBySession);
  const state = await getState();

  assert.equal(resourcesStartedBySession.ecs, false);
  assert.equal(resourcesStartedBySession.rds, false);
  assert.equal(state.rdsStatus, "available");
  assert.equal(state.ecsDesiredCount, 2);
  assert.equal(
    state.calls.some((argumentsList) => argumentsList[1] === "update-service"),
    false,
  );
  assert.equal(
    state.calls.some((argumentsList) => argumentsList[1] === "stop-db-instance"),
    false,
  );
});

test("rejects an operation lock held by a different local AWS operation", async () => {
  await setState({
    rdsStatus: "available",
    ecsDesiredCount: 1,
    ecsExists: true,
    items: {
      "test-service": {
        LockId: { S: "test-service" },
        Holder: { S: "existing-operation" },
        ExpiresAt: { N: String(Math.floor(Date.now() / 1_000) + 600) },
      },
    },
  });

  await assert.rejects(
    acquireAwsOperationLock("test-rds-rotation-lock", "competing-operation", 900, 0),
    /ConditionalCheckFailedException/,
  );
});

test("stops only resources started by the local session", async () => {
  const previousOverride = {
    LockId: { S: "manual-override" },
    Holder: { S: "previous-session" },
    ExpiresAt: { N: String(Math.floor(Date.now() / 1_000) + 6 * 60 * 60) },
  };
  await setState({
    rdsStatus: "stopped",
    ecsDesiredCount: 0,
    ecsExists: true,
    items: { "manual-override": previousOverride },
  });

  const resourcesStartedBySession = await startAwsInfrastructure();
  assert.equal(resourcesStartedBySession.ecs, true);
  assert.equal(resourcesStartedBySession.rds, true);
  const activeOverride = (await getState()).items["manual-override"];
  assert.equal(activeOverride.Holder.S, resourcesStartedBySession.manualOverride.holder);
  assert.ok(Number(activeOverride.ExpiresAt.N) >= Math.floor(Date.now() / 1_000) + 11 * 60 * 60);

  await renewManualOverride(resourcesStartedBySession.manualOverride.holder);
  const renewedOverride = (await getState()).items["manual-override"];
  assert.equal(renewedOverride.Holder.S, resourcesStartedBySession.manualOverride.holder);
  assert.ok(Number(renewedOverride.ExpiresAt.N) >= Math.floor(Date.now() / 1_000) + 11 * 60 * 60);

  await stopAwsInfrastructure(resourcesStartedBySession);
  const state = await getState();

  assert.equal(state.rdsStatus, "stopped");
  assert.equal(state.ecsDesiredCount, 0);
  assert.deepEqual(state.items["manual-override"], previousOverride);

  const drainRequestedIndex = state.calls.findIndex((argumentsList) => {
    if (argumentsList[0] !== "dynamodb" || argumentsList[1] !== "put-item") return false;
    const itemIndex = argumentsList.indexOf("--item");
    return JSON.parse(argumentsList[itemIndex + 1]).LockId.S === "bracket-preview-worker";
  });
  const scaleDownIndex = state.calls.findIndex((argumentsList) => {
    const desiredCountIndex = argumentsList.indexOf("--desired-count");
    return (
      argumentsList[0] === "ecs" &&
      argumentsList[1] === "update-service" &&
      argumentsList[desiredCountIndex + 1] === "0"
    );
  });
  const stoppedTaskVerificationIndex = state.calls.findIndex(
    (argumentsList) => argumentsList[0] === "ecs" && argumentsList[1] === "describe-tasks",
  );
  const rdsStopIndex = state.calls.findIndex(
    (argumentsList) => argumentsList[0] === "rds" && argumentsList[1] === "stop-db-instance",
  );

  assert.ok(drainRequestedIndex >= 0);
  assert.ok(drainRequestedIndex < scaleDownIndex);
  assert.ok(scaleDownIndex < stoppedTaskVerificationIndex);
  assert.ok(stoppedTaskVerificationIndex < rdsStopIndex);
});

test("waits for ECS tasks to stop before stopping RDS", async () => {
  await setState({
    rdsStatus: "stopped",
    ecsDesiredCount: 0,
    ecsExists: true,
    taskDescribePendingResponses: 2,
  });

  const resourcesStartedBySession = await startAwsInfrastructure();

  await withImmediateEcsShutdownPolling(() => stopAwsInfrastructure(resourcesStartedBySession));
  const state = await getState();

  assert.equal(state.describeTasksAttempts, 3);
  assert.equal(state.rdsStatus, "stopped");
  assert.equal(state.ecsDesiredCount, 0);
});

test("keeps RDS running when an ECS task remains active after bounded retries", async () => {
  await setState({
    rdsStatus: "stopped",
    ecsDesiredCount: 0,
    ecsExists: true,
    taskDescribeAlwaysStopping: true,
  });

  const resourcesStartedBySession = await startAwsInfrastructure();

  await withImmediateEcsShutdownPolling(() =>
    assert.rejects(
      stopAwsInfrastructure(resourcesStartedBySession),
      /não encerrou após 12 tentativas/i,
    ),
  );
  const state = await getState();

  assert.equal(state.describeTasksAttempts, 13);
  assert.equal(state.rdsStatus, "available");
  assert.equal(state.ecsDesiredCount, 0);
  assert.equal(
    state.calls.some((argumentsList) => argumentsList[1] === "stop-db-instance"),
    false,
  );
});

test("keeps RDS running when an ECS task does not exit gracefully", async () => {
  await setState({ rdsStatus: "stopped", ecsDesiredCount: 0, ecsExists: true, taskExitCode: 137 });

  const resourcesStartedBySession = await startAwsInfrastructure();

  await assert.rejects(
    stopAwsInfrastructure(resourcesStartedBySession),
    /não encerrou de forma graciosa/i,
  );
  const state = await getState();

  assert.equal(state.rdsStatus, "available");
  assert.equal(state.ecsDesiredCount, 0);
  assert.equal(
    state.calls.some((argumentsList) => argumentsList[1] === "stop-db-instance"),
    false,
  );
});

test("cleans up the RDS after a partial ECS startup failure", async () => {
  await setState({ rdsStatus: "stopped", ecsDesiredCount: 0, ecsExists: false });

  await assert.rejects(startAwsInfrastructure(), /não foi encontrado/i);
  const state = await getState();

  assert.equal(state.rdsStatus, "stopped");
  assert.equal(
    state.calls.some((argumentsList) => argumentsList[1] === "stop-db-instance"),
    true,
  );
});
