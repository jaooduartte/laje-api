import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const stateMachinePath = new URL(
  "../../infra/aws/terraform/staging-operations.asl.json",
  import.meta.url,
);
const schedulePath = new URL("../../infra/aws/terraform/nightly-operations.tf", import.meta.url);
const apiPath = new URL("../../infra/aws/terraform/staging-api.tf", import.meta.url);
const variablesPath = new URL("../../infra/aws/terraform/variables.tf", import.meta.url);

const stateMachine = JSON.parse(await readFile(stateMachinePath, "utf8"));
const scheduleTerraform = await readFile(schedulePath, "utf8");
const apiTerraform = await readFile(apiPath, "utf8");
const variableTerraform = await readFile(variablesPath, "utf8");

test("LAJE-152 state machine definition has valid state transitions", () => {
  const stateNames = new Set(Object.keys(stateMachine.States));

  for (const state of Object.values(stateMachine.States)) {
    for (const target of [
      state.Next,
      state.Default,
      ...(state.Choices ?? []).map((choice) => choice.Next),
      ...(state.Catch ?? []).map((handler) => handler.Next),
    ]) {
      if (target) assert.equal(stateNames.has(target), true, `Missing state: ${target}`);
    }
  }

  assert.equal(stateMachine.States.ChooseDrainOutcome.Choices[0].Next, "SetEcsDesiredZero");
  assert.deepEqual(stateMachine.States.VerifyStoppedTasks.Retry, [
    {
      ErrorEquals: ["Error"],
      IntervalSeconds: 15,
      BackoffRate: 1,
      MaxAttempts: 12,
    },
  ]);
  assert.equal(stateMachine.States.VerifyStoppedTasks.Catch[0].Next, "CleanupFailure");
  assert.equal(stateMachine.States.VerifyStoppedTasks.Next, "ReadRdsForStop");
  assert.equal(
    stateMachine.States.ChooseRdsStartAction.Choices.find(
      (choice) => choice.StringEquals === "backing-up",
    ).Next,
    "WaitForRdsStart",
  );
  // RDS may briefly enter this state immediately after a scheduled StartDBInstance.
  // Keep polling until available; do not start ECS early or fail the execution.
  assert.equal(
    stateMachine.States.ChooseRdsStartAction.Choices.find(
      (choice) => choice.StringEquals === "configuring-enhanced-monitoring",
    ).Next,
    "WaitForRdsStart",
  );
  assert.equal(stateMachine.States.WaitForRdsStart.Seconds, 60);
  assert.equal(stateMachine.States.WaitForRdsStart.Next, "RenewLockBeforeRdsStartCheck");
  assert.equal(stateMachine.States.RenewLockBeforeRdsStartCheck.Next, "ReadRdsForStart");
  assert.equal(
    stateMachine.States.ChooseRdsStopAction.Choices.find(
      (choice) => choice.StringEquals === "backing-up",
    ).Next,
    "WaitForRdsStop",
  );
  assert.equal(stateMachine.States.ReleaseLockAfterStart.Next, "StartSucceeded");
  assert.equal(stateMachine.States.ReleaseLockAfterStop.Next, "StopSucceeded");
});

test("LAJE-152 schedules use Sao Paulo time and stay disabled by default", () => {
  assert.match(scheduleTerraform, /schedule_expression\s+= "cron\(0 0 \* \* \? \*\)"/);
  assert.match(scheduleTerraform, /schedule_expression\s+= "cron\(0 9 \* \* \? \*\)"/);
  assert.equal(
    (scheduleTerraform.match(/schedule_expression_timezone = "America\/Sao_Paulo"/g) ?? []).length,
    2,
  );
  assert.equal(
    (
      scheduleTerraform.match(
        /state\s+= var\.staging_automation_schedules_enabled \? "ENABLED" : "DISABLED"/g,
      ) ?? []
    ).length,
    2,
  );
  assert.match(
    variableTerraform,
    /variable "staging_automation_schedules_enabled" \{[\s\S]*?default\s+= false/,
  );
});

test("LAJE-152 keeps the ALB default and gates Cloud Map cutover", () => {
  assert.match(
    variableTerraform,
    /variable "staging_api_cloud_map_enabled" \{[\s\S]*?default\s+= false/,
  );
  assert.match(
    variableTerraform,
    /variable "staging_api_use_cloud_map" \{[\s\S]*?default\s+= false/,
  );
  assert.match(
    apiTerraform,
    /var\.staging_api_use_cloud_map \? aws_service_discovery_service\.api\[0\]\.arn : aws_lb_listener\.api_http\[0\]\.arn/,
  );
  assert.match(
    apiTerraform,
    /route_key\s+= "ANY \/__laje152_canary\/{proxy\+}"[\s\S]*?authorization_type = "AWS_IAM"/,
  );
});
