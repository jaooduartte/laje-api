export type DatabaseParameter = unknown;

export type DatabaseRow = Record<string, unknown>;

export interface DatabaseQueryResult<Row extends DatabaseRow = DatabaseRow> {
  rows: Row[];
  count: number;
}

export interface DatabaseQueryExecutor {
  query<Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    parameters?: readonly DatabaseParameter[],
  ): Promise<DatabaseQueryResult<Row>>;
}

export interface DatabaseQueryAdapter extends DatabaseQueryExecutor {}

export interface DatabaseAdapter extends DatabaseQueryAdapter {
  transaction<T>(work: (adapter: DatabaseQueryAdapter) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}

export interface DatabaseConnection extends DatabaseQueryExecutor {
  checkConnection(): Promise<void>;
  transaction<T>(work: (executor: DatabaseQueryExecutor) => Promise<T>): Promise<T>;
  close(): Promise<void>;
}
