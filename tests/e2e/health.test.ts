import assert from "node:assert/strict";
import { request } from "node:http";
import test from "node:test";

import express from "express";

import { createHealthRouter } from "../../src/modules/health/health.routes.js";
import { HealthService } from "../../src/modules/health/health.service.js";

interface TestResponse {
  statusCode: number | undefined;
  body: unknown;
}

class HealthyDatabase {
  async checkConnection(): Promise<void> {}
}

class UnavailableDatabase {
  async checkConnection(): Promise<void> {
    throw new Error("database unavailable");
  }
}

function createTestApp(database: { checkConnection(): Promise<void> }) {
  const app = express();
  app.use("/api/v1/health", createHealthRouter(new HealthService(database)));
  return app;
}

function get(app: ReturnType<typeof createTestApp>, path: string): Promise<TestResponse> {
  return new Promise((resolve, reject) => {
    const server = app.listen(0, "127.0.0.1", () => {
      const address = server.address();
      assert.ok(address && typeof address === "object");

      const req = request(
        {
          host: "127.0.0.1",
          port: address.port,
          path,
          method: "GET",
        },
        (response) => {
          let body = "";
          response.setEncoding("utf8");
          response.on("data", (chunk) => {
            body += chunk;
          });
          response.on("end", () => {
            server.close((error) => {
              if (error) {
                reject(error);
                return;
              }

              resolve({
                statusCode: response.statusCode,
                body: JSON.parse(body),
              });
            });
          });
        },
      );

      req.once("error", (error) => {
        server.close(() => reject(error));
      });
      req.end();
    });

    server.once("error", reject);
  });
}

test("GET /api/v1/health returns application health without checking PostgreSQL", async () => {
  const response = await get(createTestApp(new UnavailableDatabase()), "/api/v1/health");

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.body, {
    service: "laje-api",
    status: "ok",
  });
});

test("GET /api/v1/health/database returns 200 when PostgreSQL is reachable", async () => {
  const response = await get(createTestApp(new HealthyDatabase()), "/api/v1/health/database");

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.body, {
    database: "reachable",
    status: "ok",
  });
});

test("GET /api/v1/health/database returns 503 without internal details when PostgreSQL is unavailable", async () => {
  const response = await get(createTestApp(new UnavailableDatabase()), "/api/v1/health/database");

  assert.equal(response.statusCode, 503);
  assert.deepEqual(response.body, {
    database: "unreachable",
    status: "unavailable",
  });
});
