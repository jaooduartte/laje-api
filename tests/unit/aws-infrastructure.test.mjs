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
    "AWS_RDS_INSTANCE_IDENTIFIER",
  ].map((name) => [name, process.env[name]]),
);

process.env.PATH = `${binaryDirectory}${delimiter}${originalPath ?? ""}`;
process.env.AWS_EXPECTED_ACCOUNT_ID = "111111111111";
process.env.AWS_ECS_CLUSTER = "test-cluster";
process.env.AWS_ECS_SERVICE = "test-service";
process.env.AWS_RDS_INSTANCE_IDENTIFIER = "test-database";
process.env.AWS_FIXTURE_STATE_FILE = stateFile;

const fakeAws = join(temporaryDirectory, "fake-aws.mjs");
await writeFile(
  fakeAws,
  `import { readFileSync, writeFileSync } from "node:fs";

const stateFile = process.env.AWS_FIXTURE_STATE_FILE;
const state = JSON.parse(readFileSync(stateFile, "utf8"));
const argumentsList = process.argv.slice(2);
state.calls.push(argumentsList);

function saveState() {
  writeFileSync(stateFile, JSON.stringify(state));
}

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
} else if (argumentsList[0] === "ecs" && argumentsList[1] === "wait") {
  process.stdout.write("");
} else {
  process.stderr.write("Unexpected AWS CLI arguments: " + argumentsList.join(" "));
  process.exitCode = 1;
}
`,
);
const awsExecutable = join(binaryDirectory, "aws");
await writeFile(awsExecutable, `#!/bin/sh\nexec node "${fakeAws}" "$@"\n`);
await chmod(awsExecutable, 0o755);

const { startAwsInfrastructure, stopAwsInfrastructure } =
  await import("../../scripts/aws-infrastructure.mjs");

async function setState(state) {
  await writeFile(stateFile, JSON.stringify({ account: "111111111111", calls: [], ...state }));
}

async function getState() {
  return JSON.parse(await readFile(stateFile, "utf8"));
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

  assert.deepEqual(resourcesStartedBySession, { ecs: false, rds: false });
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

test("stops only resources started by the local session", async () => {
  await setState({ rdsStatus: "stopped", ecsDesiredCount: 0, ecsExists: true });

  const resourcesStartedBySession = await startAwsInfrastructure();
  assert.deepEqual(resourcesStartedBySession, { ecs: true, rds: true });
  await stopAwsInfrastructure(resourcesStartedBySession);
  const state = await getState();

  assert.equal(state.rdsStatus, "stopped");
  assert.equal(state.ecsDesiredCount, 0);
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
