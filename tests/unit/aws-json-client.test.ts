import assert from "node:assert/strict";
import test from "node:test";

import { awsJsonRequest } from "../../src/integrations/aws/aws-json.client.js";

test("signs DynamoDB JSON protocol requests with the service-specific scope", async () => {
  const environmentNames = [
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
  ];
  const originalEnvironment = new Map(environmentNames.map((name) => [name, process.env[name]]));
  const originalFetch = globalThis.fetch;
  let requestUrl = "";
  let requestHeaders = new Headers();
  process.env.AWS_ACCESS_KEY_ID = "test-access-key";
  process.env.AWS_SECRET_ACCESS_KEY = "test-secret-key";
  delete process.env.AWS_SESSION_TOKEN;
  delete process.env.AWS_CONTAINER_CREDENTIALS_FULL_URI;
  delete process.env.AWS_CONTAINER_CREDENTIALS_RELATIVE_URI;
  globalThis.fetch = async (input, init) => {
    requestUrl = String(input);
    requestHeaders = new Headers(init?.headers);
    return new Response("{}", { status: 200 });
  };

  try {
    const response = await awsJsonRequest("sa-east-1", "dynamodb", "DynamoDB_20120810.GetItem", {
      TableName: "test-locks",
    });

    assert.deepEqual(response, {});
    assert.equal(requestUrl, "https://dynamodb.sa-east-1.amazonaws.com/");
    assert.equal(requestHeaders.get("x-amz-target"), "DynamoDB_20120810.GetItem");
    assert.match(
      requestHeaders.get("authorization") ?? "",
      /Credential=test-access-key\/\d{8}\/sa-east-1\/dynamodb\/aws4_request/,
    );
  } finally {
    globalThis.fetch = originalFetch;
    for (const [name, value] of originalEnvironment) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});

test("preserves DynamoDB conditional failure codes for idempotent worker draining", async () => {
  const originalEnvironment = new Map(
    ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"].map((name) => [name, process.env[name]]),
  );
  const originalFetch = globalThis.fetch;
  process.env.AWS_ACCESS_KEY_ID = "test-access-key";
  process.env.AWS_SECRET_ACCESS_KEY = "test-secret-key";
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({
        __type: "com.amazon.coral#ConditionalCheckFailedException",
        message: "Condition did not match",
      }),
      { status: 400 },
    );

  try {
    await assert.rejects(
      awsJsonRequest("sa-east-1", "dynamodb", "DynamoDB_20120810.UpdateItem", {}),
      (error: unknown) =>
        error instanceof Error && error.name === "ConditionalCheckFailedException",
    );
  } finally {
    globalThis.fetch = originalFetch;
    for (const [name, value] of originalEnvironment) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
});
