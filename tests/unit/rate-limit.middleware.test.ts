import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";

import express from "express";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.DATABASE_URL = "postgresql://laje:laje@localhost:5432/laje";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "false";

const [{ createSensitiveRouteRateLimit }, { errorHandler }] = await Promise.all([
  import("../../src/common/middlewares/rate-limit.middleware.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
]);

test("LAJE-146 shares quota through atomic PostgreSQL commands and returns 429", async (t) => {
  const seen: Array<{ sql: string; params: readonly unknown[] }> = [];
  let count = 0;
  const executor = {
    query: async <Row extends Record<string, unknown> = Record<string, unknown>>(sql: string, params: readonly unknown[] = []) => {
      seen.push({ sql, params });
      count++;
      return {
        rows: [{ hits: count, window_bucket: Math.floor(Date.now() / 60_000) }] as unknown as Row[],
        count: 1,
      };
    },
  };
  const app = express();
  app.post("/protected", createSensitiveRouteRateLimit({
    scope: "auth-login", maxRequests: 2, windowSeconds: 60,
    executor, enabled: true,
  }), (_req, res) => { res.status(204).end(); });
  app.use(errorHandler);
  const server = app.listen(0, "127.0.0.1");
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  }));
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const url = `http://127.0.0.1:${address.port}/protected`;
  const first = await fetch(url, { method: "POST", headers: { "x-forwarded-for": "8.8.8.8" } });
  const second = await fetch(url, { method: "POST", headers: { "x-forwarded-for": "7.7.7.7" } });
  const third = await fetch(url, { method: "POST" });
  assert.equal(first.status, 204);
  assert.equal(second.status, 204);
  assert.equal(third.status, 429);
  assert.equal((await third.json()).error.code, "RATE_LIMIT_EXCEEDED");
  assert.equal(third.headers.get("ratelimit-limit"), "2");
  assert.equal(third.headers.get("ratelimit-remaining"), "0");
  assert.ok(Number(third.headers.get("retry-after")) > 0);
  assert.equal(seen.length, 3);
  assert.match(seen[0]!.sql, /ON CONFLICT \(key_hash\) DO UPDATE/);
  assert.deepEqual(seen[0]!.params.slice(1), [60]);
  assert.match(String(seen[0]!.params[0]), /^[0-9a-f]{64}$/);
  assert.equal(seen[0]!.params[0], seen[1]!.params[0], "untrusted XFF must not bypass the limit");
  assert.equal(seen[1]!.params[0], seen[2]!.params[0]);
});

test("LAJE-146 is disabled only when the administrative module is disabled", async (t) => {
  const app = express();
  app.post("/disabled", createSensitiveRouteRateLimit({
    scope: "auth-disabled", maxRequests: 1, windowSeconds: 60,
    enabled: false,
    executor: { query: async () => { throw new Error("must never call DB"); } },
  }), (_req, res) => { res.status(204).end(); });
  const server = app.listen(0, "127.0.0.1");
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  }));
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  assert.equal((await fetch(`http://127.0.0.1:${address.port}/disabled`, { method: "POST" })).status, 204);
});

test("LAJE-146 fails closed if the shared store is unavailable", async (t) => {
  const app = express();
  app.post("/protected", createSensitiveRouteRateLimit({
    scope: "auth-test-fail", maxRequests: 2, windowSeconds: 60,
    enabled: true,
    executor: { query: async () => { throw new Error("PostgreSQL unavailable"); } },
  }), (_req, res) => { res.status(204).end(); });
  app.use(errorHandler);
  const server = app.listen(0, "127.0.0.1");
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  }));
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const response = await fetch(`http://127.0.0.1:${address.port}/protected`, { method: "POST" });
  assert.equal(response.status, 500);
  assert.equal((await response.json()).error.code, "INTERNAL_SERVER_ERROR");
});

test("LAJE-146 rejects invalid limiter configuration", () => {
  assert.throws(() => createSensitiveRouteRateLimit({
    scope: "invalid scope", maxRequests: 1, windowSeconds: 60,
  }), /Invalid rate limit configuration/);
});
