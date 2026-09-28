import assert from "node:assert/strict";
import { request } from "node:http";
import test from "node:test";

import express from "express";

import { openApiDocument } from "../../src/openapi/openapi.document.js";
import {
  createOpenApiRouter,
  isApiDocumentationEnabled,
} from "../../src/openapi/openapi.routes.js";

interface TestResponse {
  statusCode: number | undefined;
  body: string;
}

function createTestApp() {
  const app = express();
  app.use("/api-docs", createOpenApiRouter());
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
                body,
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

test("OpenAPI documentation is enabled only in development", () => {
  assert.equal(isApiDocumentationEnabled("development"), true);
  assert.equal(isApiDocumentationEnabled("test"), false);
  assert.equal(isApiDocumentationEnabled("production"), false);
});

test("OpenAPI document includes current healthchecks and the future bearer scheme", () => {
  assert.equal(openApiDocument.openapi, "3.1.0");
  assert.ok(openApiDocument.paths["/api/v1/health"]);
  assert.ok(openApiDocument.paths["/api/v1/health/database"]);
  assert.equal(openApiDocument.components.securitySchemes.bearerAuth.scheme, "bearer");
});

test("GET /api-docs/openapi.json serves the local OpenAPI document", async () => {
  const response = await get(createTestApp(), "/api-docs/openapi.json");

  assert.equal(response.statusCode, 200);
  assert.deepEqual(JSON.parse(response.body), openApiDocument);
});

test("GET /api-docs serves the Swagger UI shell", async () => {
  const response = await get(createTestApp(), "/api-docs");

  assert.equal(response.statusCode, 200);
  assert.match(response.body, /SwaggerUIBundle/);
  assert.match(response.body, /\/api-docs\/openapi\.json/);
});
