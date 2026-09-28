import assert from "node:assert/strict";
import test from "node:test";

import { DatabaseClient } from "../../src/database/client.js";
import { BaseRepository } from "../../src/database/repository.js";
import type {
  DatabaseAdapter,
  DatabaseQueryAdapter,
  DatabaseQueryExecutor,
  DatabaseQueryResult,
  DatabaseRow,
} from "../../src/database/types.js";

class FakeQueryAdapter implements DatabaseQueryAdapter {
  public statements: Array<{ statement: string; parameters: readonly unknown[] }> = [];
  public error: Error | undefined;

  async query<Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    parameters: readonly unknown[] = [],
  ): Promise<DatabaseQueryResult<Row>> {
    this.statements.push({ statement, parameters });
    if (this.error) throw this.error;

    return {
      rows: [{ ok: 1 } as unknown as Row],
      count: 1,
    };
  }
}

class FakeAdapter extends FakeQueryAdapter implements DatabaseAdapter {
  public transactionAdapter = new FakeQueryAdapter();
  public transactionCalls = 0;
  public closeCalls = 0;

  async transaction<T>(work: (adapter: DatabaseQueryAdapter) => Promise<T>): Promise<T> {
    this.transactionCalls += 1;
    return work(this.transactionAdapter);
  }

  async close(): Promise<void> {
    this.closeCalls += 1;
  }
}

class TestRepository extends BaseRepository {
  constructor(database: DatabaseQueryExecutor) {
    super(database);
  }

  async findMarker(): Promise<number> {
    const result = await this.database.query<{ marker: number }>("SELECT $1::int AS marker", [7]);
    return result.rows[0]?.marker ?? 0;
  }
}

test("DatabaseClient validates connectivity with a lightweight query", async () => {
  const adapter = new FakeAdapter();
  const database = new DatabaseClient(adapter);

  await database.checkConnection();

  assert.deepEqual(adapter.statements, [{ statement: "SELECT 1 AS connection_ok", parameters: [] }]);
});

test("DatabaseClient propagates connection failures", async () => {
  const adapter = new FakeAdapter();
  const expectedError = new Error("database unavailable");
  adapter.error = expectedError;
  const database = new DatabaseClient(adapter);

  await assert.rejects(database.checkConnection(), expectedError);
});

test("DatabaseClient executes transactions through a scoped executor", async () => {
  const adapter = new FakeAdapter();
  const database = new DatabaseClient(adapter);

  const result = await database.transaction(async (transaction) => {
    const query = await transaction.query("SELECT $1::int AS ok", [1]);
    return query.count;
  });

  assert.equal(result, 1);
  assert.equal(adapter.transactionCalls, 1);
  assert.deepEqual(adapter.statements, []);
  assert.deepEqual(adapter.transactionAdapter.statements, [
    { statement: "SELECT $1::int AS ok", parameters: [1] },
  ]);
});

test("DatabaseClient closes its connection pool", async () => {
  const adapter = new FakeAdapter();
  const database = new DatabaseClient(adapter);

  await database.close();

  assert.equal(adapter.closeCalls, 1);
});

test("BaseRepository receives a query executor instead of importing a global connection", async () => {
  const executor: DatabaseQueryExecutor = {
    async query<Row extends DatabaseRow = DatabaseRow>(
      statement: string,
      parameters: readonly unknown[] = [],
    ): Promise<DatabaseQueryResult<Row>> {
      assert.equal(statement, "SELECT $1::int AS marker");
      assert.deepEqual(parameters, [7]);
      return { rows: [{ marker: 7 } as unknown as Row], count: 1 };
    },
  };

  const repository = new TestRepository(executor);

  assert.equal(await repository.findMarker(), 7);
});
