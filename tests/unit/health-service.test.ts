import assert from "node:assert/strict";
import test from "node:test";

import { HealthService } from "../../src/modules/health/health.service.js";

class HealthyDatabase {
  checks = 0;

  async checkConnection(): Promise<void> {
    this.checks += 1;
  }
}

class UnavailableDatabase {
  async checkConnection(): Promise<void> {
    throw new Error("database connection failed with internal diagnostic details");
  }
}

test("application health is independent from database connectivity", () => {
  const database = new HealthyDatabase();
  const service = new HealthService(database);

  assert.deepEqual(service.getApplicationHealth(), {
    service: "laje-api",
    status: "ok",
  });
  assert.equal(database.checks, 0);
});

test("database health reports availability when the connection succeeds", async () => {
  const database = new HealthyDatabase();
  const service = new HealthService(database);

  assert.deepEqual(await service.getDatabaseHealth(), {
    database: "reachable",
    status: "ok",
  });
  assert.equal(database.checks, 1);
});

test("database health reports unavailability without leaking the connection error", async () => {
  const service = new HealthService(new UnavailableDatabase());
  const result = await service.getDatabaseHealth();

  assert.deepEqual(result, {
    database: "unreachable",
    status: "unavailable",
  });
  assert.equal(JSON.stringify(result).includes("internal diagnostic details"), false);
});
