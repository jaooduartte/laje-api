import postgres from "postgres";

import type {
  DatabaseAdapter,
  DatabaseQueryAdapter,
  DatabaseQueryResult,
  DatabaseRow,
} from "./types.js";

interface PostgresResult<Row extends DatabaseRow> extends Array<Row> {
  count: number | null;
}

interface PostgresSql {
  unsafe<Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    parameters?: unknown[],
  ): PromiseLike<PostgresResult<Row>>;
  begin<T>(work: (sql: PostgresSql) => Promise<T>): Promise<T>;
  end(options?: { timeout?: number | null }): Promise<void>;
}

export interface PostgresAdapterOptions {
  url: string;
  maxConnections: number;
  idleTimeoutSeconds: number;
  connectTimeoutSeconds: number;
  shutdownTimeoutSeconds: number;
  applicationName?: string;
}

class PostgresQueryAdapter implements DatabaseQueryAdapter {
  constructor(protected readonly sql: PostgresSql) {}

  async query<Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    parameters: readonly unknown[] = [],
  ): Promise<DatabaseQueryResult<Row>> {
    const result = await this.sql.unsafe<Row>(statement, [...parameters]);

    return {
      rows: Array.from(result),
      count: result.count ?? result.length,
    };
  }
}

class PostgresAdapter extends PostgresQueryAdapter implements DatabaseAdapter {
  constructor(
    sql: PostgresSql,
    private readonly shutdownTimeoutSeconds: number,
  ) {
    super(sql);
  }

  transaction<T>(work: (adapter: DatabaseQueryAdapter) => Promise<T>): Promise<T> {
    return this.sql.begin(async (transactionSql) => work(new PostgresQueryAdapter(transactionSql)));
  }

  close(): Promise<void> {
    return this.sql.end({ timeout: this.shutdownTimeoutSeconds });
  }
}

export function createPostgresAdapter(options: PostgresAdapterOptions): DatabaseAdapter {
  const sql = postgres(options.url, {
    max: options.maxConnections,
    idle_timeout: options.idleTimeoutSeconds,
    connect_timeout: options.connectTimeoutSeconds,
    connection: {
      application_name: options.applicationName ?? "laje-api",
    },
  }) as unknown as PostgresSql;

  return new PostgresAdapter(sql, options.shutdownTimeoutSeconds);
}
