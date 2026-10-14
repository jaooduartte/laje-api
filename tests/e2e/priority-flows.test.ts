import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.DATABASE_URL = "postgresql://laje:laje@localhost:5432/laje";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "false";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const { app } = await import("../../src/app.js");

test("LAJE-38: checks API flow boundaries", async (t) => {
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
  const url = `http://127.0.0.1:${address.port}/api/v1`;

  // Flow 1: login request is validated before accessing credentials/storage.
  const login = await fetch(`${url}/auth/sessions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(login.status, 422);
  assert.equal((await login.json()).error.code, "VALIDATION_ERROR");

  // Flow 2: live score changes cannot bypass disabled administrative auth.
  const liveControl = await fetch(`${url}/matches/b37e22a1-8181-43b2-98a1-29db7e864f0a/start`, {
    method: "POST",
  });
  assert.equal(liveControl.status, 401);
  assert.equal((await liveControl.json()).error.code, "ACCESS_TOKEN_REQUIRED");

  // Flow 3: public championship and match filters reject invalid input.
  const championships = await fetch(`${url}/championships?code=INVALID`);
  assert.equal(championships.status, 422);
  assert.equal((await championships.json()).error.code, "VALIDATION_ERROR");

  const matches = await fetch(`${url}/matches?status=INVALID`);
  assert.equal(matches.status, 422);
  assert.equal((await matches.json()).error.code, "VALIDATION_ERROR");
});
