import assert from "node:assert/strict";
import test, { type TestContext } from "node:test";

import { AwsDynamoDbClient } from "../../src/integrations/aws/dynamodb.client.js";

function setCredentials(t: TestContext): void {
  const environmentNames = [
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
  ];
  const originalEnvironment = new Map(environmentNames.map((name) => [name, process.env[name]]));

  t.after(() => {
    for (const [name, value] of originalEnvironment) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  process.env.AWS_ACCESS_KEY_ID = "test-access-key";
  process.env.AWS_SECRET_ACCESS_KEY = "test-secret-key";
  delete process.env.AWS_SESSION_TOKEN;
  delete process.env.AWS_CONTAINER_CREDENTIALS_FULL_URI;
  delete process.env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI;
}

test("reads bracket preview worker drain state from DynamoDB", async (t) => {
  setCredentials(t);
  const responses = [
    JSON.stringify({}),
    JSON.stringify({ Item: { State: { S: "DRAINING" } } }),
    JSON.stringify({ Item: { State: { S: "DRAINING" }, OperationId: { S: "nightly-stop" } } }),
  ];
  let responseIndex = 0;
  t.mock.method(
    globalThis,
    "fetch",
    async () => new Response(responses[responseIndex++], { status: 200 }),
  );

  const client = new AwsDynamoDbClient("sa-east-1", "worker-locks");

  assert.equal(await client.getBracketPreviewWorkerDrainState(), null);
  assert.equal(await client.getBracketPreviewWorkerDrainState(), null);
  assert.deepEqual(await client.getBracketPreviewWorkerDrainState(), {
    state: "DRAINING",
    operationId: "nightly-stop",
  });
});

test("marks the worker drained with an operation-scoped conditional update", async (t) => {
  setCredentials(t);
  let requestPayload: Record<string, unknown> = {};
  t.mock.method(
    globalThis,
    "fetch",
    async (_input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      requestPayload = JSON.parse(String(init?.body)) as Record<string, unknown>;
      return new Response("{}", { status: 200 });
    },
  );

  const client = new AwsDynamoDbClient("sa-east-1", "worker-locks");

  assert.equal(await client.markBracketPreviewWorkerDrained("nightly-stop"), true);
  assert.equal(
    requestPayload.ConditionExpression,
    "#state = :draining AND OperationId = :operationId",
  );
  assert.deepEqual(requestPayload.ExpressionAttributeValues, {
    ":draining": { S: "DRAINING" },
    ":drained": { S: "DRAINED" },
    ":operationId": { S: "nightly-stop" },
  });
});

test("returns false for a stale worker drain operation and propagates other DynamoDB errors", async (t) => {
  setCredentials(t);
  const responses = [
    new Response(JSON.stringify({ __type: "com.amazon.coral#ConditionalCheckFailedException" }), {
      status: 400,
    }),
    new Response(JSON.stringify({ __type: "com.amazon.coral#ResourceNotFoundException" }), {
      status: 400,
    }),
  ];
  let responseIndex = 0;
  t.mock.method(globalThis, "fetch", async () => responses[responseIndex++]!);

  const client = new AwsDynamoDbClient("sa-east-1", "worker-locks");

  assert.equal(await client.markBracketPreviewWorkerDrained("stale-operation"), false);
  await assert.rejects(
    client.markBracketPreviewWorkerDrained("missing-table"),
    (error: unknown) => error instanceof Error && error.name === "ResourceNotFoundException",
  );
});
