import { databaseConfig } from "../config/database.config.js";
import { DatabaseClient } from "./client.js";
import { createPostgresAdapter } from "./postgres-adapter.js";

const adapter = createPostgresAdapter({
  url: databaseConfig.url,
  maxConnections: databaseConfig.maxConnections,
  idleTimeoutSeconds: databaseConfig.idleTimeoutSeconds,
  connectTimeoutSeconds: databaseConfig.connectTimeoutSeconds,
  shutdownTimeoutSeconds: databaseConfig.shutdownTimeoutSeconds,
});

export const database = new DatabaseClient(adapter);

export { BaseRepository } from "./repository.js";
export type {
  DatabaseConnection,
  DatabaseParameter,
  DatabaseQueryExecutor,
  DatabaseQueryResult,
  DatabaseRow,
} from "./types.js";
