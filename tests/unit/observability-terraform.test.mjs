import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const terraform = await readFile(
  new URL("../../infra/aws/terraform/observability.tf", import.meta.url),
  "utf8",
);
const apiTerraform = await readFile(
  new URL("../../infra/aws/terraform/staging-api.tf", import.meta.url),
  "utf8",
);

test("LAJE-40 provisions a dashboard and retains sanitized access logs for 7 days", () => {
  assert.match(terraform, /resource "aws_cloudwatch_dashboard" "staging_observability"/);
  assert.match(terraform, /resource "aws_cloudwatch_log_group" "api_gateway_access"/);
  assert.match(terraform, /retention_in_days\s+= 7/);
  assert.match(terraform, /"AWS\/ApiGateway"/);
  assert.match(terraform, /"AWS\/ECS"/);
  assert.match(terraform, /"AWS\/RDS"/);
  assert.match(terraform, /"AWS\/SQS"/);
  assert.match(apiTerraform, /access_log_settings\s+\{/);
  assert.match(
    apiTerraform,
    /destination_arn = aws_cloudwatch_log_group\.api_gateway_access\[0\]\.arn/,
  );
  assert.match(apiTerraform, /requestId\s+= "\$context\.requestId"/);
  for (const prohibited of [
    "$context.identity.sourceIp",
    "$context.path",
    "$context.requestOverride",
    "$context.authorizer",
    "$context.requestBody",
  ]) {
    assert.equal(
      apiTerraform.includes(prohibited),
      false,
      `Forbidden access-log field: ${prohibited}`,
    );
  }
});
