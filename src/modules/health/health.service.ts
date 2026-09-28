import type { ApplicationHealthResponse, DatabaseHealthResponse } from "./health.schema.js";

export interface HealthDatabase {
  checkConnection(): Promise<void>;
}

export class HealthService {
  constructor(private readonly database: HealthDatabase) {}

  getApplicationHealth(): ApplicationHealthResponse {
    return {
      service: "laje-api",
      status: "ok",
    };
  }

  async getDatabaseHealth(): Promise<DatabaseHealthResponse> {
    try {
      await this.database.checkConnection();

      return {
        database: "reachable",
        status: "ok",
      };
    } catch {
      return {
        database: "unreachable",
        status: "unavailable",
      };
    }
  }
}
