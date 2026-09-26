import assert from "node:assert/strict";
import { request } from "node:http";
import test from "node:test";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.DATABASE_URL = "postgresql://laje:laje@localhost:5432/laje";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "false";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const { app } = await import("../../src/app.js");

function getRoot(port: number): Promise<{ statusCode?: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request(
      {
        host: "127.0.0.1",
        port,
        path: "/api/v1",
        method: "GET",
      },
      (response) => {
        let body = "";
        response.setEncoding("utf8");
        response.on("data", (chunk) => {
          body += chunk;
        });
        response.on("end", () => {
          resolve({ statusCode: response.statusCode, body });
        });
      },
    );

    req.once("error", reject);
    req.end();
  });
}

test("GET /api/v1 returns service metadata", async (t) => {
  const server = app.listen(0);

  await new Promise<void>((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
  });

  t.after(
    () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => {
          if (error) reject(error);
          else resolve();
        });
      }),
  );

  const address = server.address();
  assert.ok(address && typeof address === "object");

  const response = await getRoot(address.port);
  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), {
    service: "laje-api",
    version: "v1",
    status: "ready",
  });
});
