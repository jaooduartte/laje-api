import assert from "node:assert/strict";
import test from "node:test";

import { openApiDocument } from "../../src/openapi/openapi.document.js";

const implementedOperations = [
  ["/api/v1/league-events", "get"],
  ["/api/v1/league-events", "post"],
  ["/api/v1/league-events/years", "get"],
  ["/api/v1/league-events/{eventId}", "put"],
  ["/api/v1/league-events/{eventId}", "delete"],
  ["/api/v1/league-events/reservation-requests", "get"],
  ["/api/v1/league-events/reservation-requests", "post"],
  ["/api/v1/league-events/reservation-requests/conflicts", "get"],
  ["/api/v1/league-events/reservation-requests/pending-count", "get"],
  ["/api/v1/league-events/reservation-requests/{requestId}/review", "post"],
  ["/api/v1/public/settings", "get"],
  ["/api/v1/public/settings", "put"],
  ["/api/v1/public/links", "get"],
  ["/api/v1/public/links/admin", "get"],
  ["/api/v1/public/link-sections", "post"],
  ["/api/v1/public/link-sections/{sectionId}", "put"],
  ["/api/v1/public/link-sections/{sectionId}", "delete"],
  ["/api/v1/public/link-items", "post"],
  ["/api/v1/public/link-items/{itemId}", "put"],
  ["/api/v1/public/link-items/{itemId}", "delete"],
] as const;

test("LAJE-87 OpenAPI marks all migrated public-content operations as implemented", () => {
  for (const [path, method] of implementedOperations) {
    const pathItem = openApiDocument.paths[path];
    assert.ok(pathItem, `Missing OpenAPI path ${path}`);

    const operation = pathItem[method];
    assert.ok(operation, `Missing OpenAPI operation ${method.toUpperCase()} ${path}`);
    assert.equal(operation["x-implementation-status"], "implemented");
  }
});

test("administrative LAJE-87 operations require bearer authentication", () => {
  const protectedOperations = [
    ["/api/v1/league-events", "post"],
    ["/api/v1/league-events/{eventId}", "put"],
    ["/api/v1/league-events/{eventId}", "delete"],
    ["/api/v1/league-events/reservation-requests", "get"],
    ["/api/v1/league-events/reservation-requests/pending-count", "get"],
    ["/api/v1/league-events/reservation-requests/{requestId}/review", "post"],
    ["/api/v1/public/settings", "put"],
    ["/api/v1/public/links/admin", "get"],
    ["/api/v1/public/link-sections", "post"],
    ["/api/v1/public/link-sections/{sectionId}", "put"],
    ["/api/v1/public/link-sections/{sectionId}", "delete"],
    ["/api/v1/public/link-items", "post"],
    ["/api/v1/public/link-items/{itemId}", "put"],
    ["/api/v1/public/link-items/{itemId}", "delete"],
  ] as const;

  for (const [path, method] of protectedOperations) {
    const operation = openApiDocument.paths[path][method];
    assert.deepEqual(operation.security, [{ bearerAuth: [] }]);
  }
});

test("public reservation conflict contract is unauthenticated and explicitly sanitized", () => {
  const operation =
    openApiDocument.paths["/api/v1/league-events/reservation-requests/conflicts"].get;

  assert.equal("security" in operation, false);
  assert.match(operation.summary, /sem dados pessoais/i);
});
