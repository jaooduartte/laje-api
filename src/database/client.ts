import { runInTransaction } from "./transaction.js";
import type {
  DatabaseAdapter,
  DatabaseConnection,
  DatabaseQueryExecutor,
  DatabaseQueryResult,
  DatabaseRow,
} from "./types.js";

export class DatabaseClient implements DatabaseConnection {
  constructor(private readonly adapter: DatabaseAdapter) {}

  query<Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    parameters?: readonly unknown[],
  ): Promise<DatabaseQueryResult<Row>> {
    return this.adapter.query<Row>(statement, parameters);
  }

  async checkConnection(): Promise<void> {
    await this.query("SELECT 1 AS connection_ok");
  }

  transaction<T>(work: (executor: DatabaseQueryExecutor) => Promise<T>): Promise<T> {
    return runInTransaction(this.adapter, work);
  }

  close(): Promise<void> {
    return this.adapter.close();
  }
}
