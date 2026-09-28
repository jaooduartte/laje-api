import type {
  DatabaseAdapter,
  DatabaseQueryExecutor,
  DatabaseQueryResult,
  DatabaseRow,
} from "./types.js";

export async function runInTransaction<T>(
  adapter: DatabaseAdapter,
  work: (executor: DatabaseQueryExecutor) => Promise<T>,
): Promise<T> {
  return adapter.transaction(async (transactionAdapter) => {
    const executor: DatabaseQueryExecutor = {
      query<Row extends DatabaseRow = DatabaseRow>(
        statement: string,
        parameters?: readonly unknown[],
      ): Promise<DatabaseQueryResult<Row>> {
        return transactionAdapter.query<Row>(statement, parameters);
      },
    };

    return work(executor);
  });
}
