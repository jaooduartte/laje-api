import assert from "node:assert/strict";
import test from "node:test";

import { AwsSqsClient } from "../../src/integrations/aws/sqs.client.js";

test("SQS signs canonical headers in a stable locale order", async (t) => {
  const previousCredentials = {
    AWS_ACCESS_KEY_ID: process.env.AWS_ACCESS_KEY_ID,
    AWS_SECRET_ACCESS_KEY: process.env.AWS_SECRET_ACCESS_KEY,
    AWS_SESSION_TOKEN: process.env.AWS_SESSION_TOKEN,
  };
  t.after(() => {
    for (const [key, value] of Object.entries(previousCredentials)) {
      if (value === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = value;
      }
    }
  });

  process.env.AWS_ACCESS_KEY_ID = "test-access-key";
  process.env.AWS_SECRET_ACCESS_KEY = "test-secret-key";
  process.env.AWS_SESSION_TOKEN = "test-session-token";

  let authorization = "";
  t.mock.method(
    globalThis,
    "fetch",
    async (_input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      authorization = new Headers(init?.headers).get("authorization") ?? "";
      return new Response("{}", { status: 200 });
    },
  );

  await new AwsSqsClient("us-east-1", "https://sqs.us-east-1.amazonaws.com/123/queue").sendMessage(
    "message",
  );

  assert.match(
    authorization,
    /SignedHeaders=content-type;host;x-amz-date;x-amz-security-token;x-amz-target/,
  );
});
