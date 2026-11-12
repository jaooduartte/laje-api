import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";

import express from "express";

import { observeRequests } from "../../src/common/middlewares/observability.middleware.js";
import { createClientErrorsRouter } from "../../src/modules/observability/client-errors.routes.js";

test("LAJE-40 assigns a correlation ID and accepts only sanitized AWS frontend telemetry", async (t) => {
  const app = express();
  app.use(observeRequests);
  app.use(express.json());
  app.use("/client-errors", createClientErrorsRouter(["http://localhost:8080"]));
  app.get("/failed", (_request, response) => response.status(503).end());

  const server = app.listen(0, "127.0.0.1");
  t.after(
    () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      }),
  );
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const baseUrl = `http://127.0.0.1:${address.port}`;

  const failed = await fetch(`${baseUrl}/failed`);
  const requestId = failed.headers.get("x-request-id");
  assert.equal(failed.status, 503);
  assert.match(requestId ?? "", /^[0-9a-f-]{36}$/);

  const headers = { origin: "http://localhost:8080", "content-type": "application/json" };
  const valid = await fetch(`${baseUrl}/client-errors`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      kind: "api-http",
      status: 503,
      code: "UPSTREAM_UNAVAILABLE",
      requestId,
    }),
  });
  assert.equal(valid.status, 204);

  const privateData = await fetch(`${baseUrl}/client-errors`, {
    method: "POST",
    headers,
    body: JSON.stringify({ kind: "javascript", message: "private user details" }),
  });
  assert.equal(privateData.status, 400);

  const invalidCorrelation = await fetch(`${baseUrl}/client-errors`, {
    method: "POST",
    headers,
    body: JSON.stringify({ kind: "api-http", requestId: "<script>alert(1)</script>" }),
  });
  assert.equal(invalidCorrelation.status, 400);

  const wrongOrigin = await fetch(`${baseUrl}/client-errors`, {
    method: "POST",
    headers: { ...headers, origin: "https://invalid.example" },
    body: JSON.stringify({ kind: "javascript" }),
  });
  assert.equal(wrongOrigin.status, 403);
});
