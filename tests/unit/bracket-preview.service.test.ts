import assert from "node:assert/strict";
import test from "node:test";

import type {
  DatabaseConnection,
  DatabaseQueryExecutor,
  DatabaseQueryResult,
  DatabaseRow,
} from "../../src/database/types.js";
import {
  BracketPreviewService,
  exactPreviewJobStatus,
} from "../../src/modules/bracket-preview/bracket-preview.service.js";

interface RecordedQuery {
  sql: string;
  parameters: readonly unknown[];
}

function createDatabase(
  handler: (
    sql: string,
    parameters: readonly unknown[],
  ) => Promise<DatabaseQueryResult> | DatabaseQueryResult,
) {
  const calls: RecordedQuery[] = [];
  const executor: DatabaseQueryExecutor = {
    async query<Row extends DatabaseRow = DatabaseRow>(
      sql: string,
      parameters: readonly unknown[] = [],
    ): Promise<DatabaseQueryResult<Row>> {
      calls.push({ sql, parameters });
      return (await handler(sql, parameters)) as DatabaseQueryResult<Row>;
    },
  };
  const database = {
    ...executor,
    async checkConnection() {},
    async close() {},
    async transaction<T>(work: (transaction: DatabaseQueryExecutor) => Promise<T>): Promise<T> {
      return work(executor);
    },
  } as DatabaseConnection;
  return { database, calls };
}

function result(rows: DatabaseRow[] = []): DatabaseQueryResult {
  return { rows, count: rows.length };
}

test("starts the exact preview under the authenticated identity and publishes one SQS message", async () => {
  const job = {
    job_id: "11111111-1111-4111-8111-111111111111",
    championship_id: "22222222-2222-4222-8222-222222222222",
    status: "QUEUED",
  };
  const { database, calls } = createDatabase((sql) => {
    if (sql.includes("set_config('laje.request_user_id'")) return result();
    if (sql.includes("start_championship_bracket_preview_job")) {
      return result([{ job }]);
    }
    throw new Error(`Unexpected SQL: ${sql}`);
  });
  const published: Array<{ jobId: string; delaySeconds: number | undefined }> = [];
  const service = new BracketPreviewService(database, {
    async sendProcessJob(jobId, delaySeconds) {
      published.push({ jobId, delaySeconds });
    },
  });

  const created = await service.start(
    "22222222-2222-4222-8222-222222222222",
    { competitions: [], schedule_days: [] },
    "33333333-3333-4333-8333-333333333333",
  );

  assert.equal(created.job_id, job.job_id);
  assert.equal(exactPreviewJobStatus(created), "QUEUED");
  assert.deepEqual(published, [{ jobId: job.job_id, delaySeconds: undefined }]);
  assert.equal(calls[0]?.parameters[0], "33333333-3333-4333-8333-333333333333");
});

test("rejects oversized preview payloads before touching PostgreSQL or SQS", async () => {
  const { database, calls } = createDatabase(() => result());
  let published = 0;
  const service = new BracketPreviewService(database, {
    async sendProcessJob() {
      published += 1;
    },
  });

  await assert.rejects(
    () =>
      service.start(
        "22222222-2222-4222-8222-222222222222",
        { oversized: "x".repeat(2 * 1024 * 1024 + 128) },
        "33333333-3333-4333-8333-333333333333",
      ),
    (error: unknown) =>
      error instanceof Error && error.message.includes("excede o limite seguro de 2 MiB"),
  );

  assert.equal(calls.length, 0);
  assert.equal(published, 0);
});

test("delegates resumable processing to the exact v8 engine and schedules only the requested continuation", async () => {
  const { database } = createDatabase((sql) => {
    if (sql.includes("championship_bracket_preview_private.process_job")) {
      return result([{ result: { continue: true, delay: 7 } }]);
    }
    throw new Error(`Unexpected SQL: ${sql}`);
  });
  const published: Array<{ jobId: string; delaySeconds: number | undefined }> = [];
  const service = new BracketPreviewService(database, {
    async sendProcessJob(jobId, delaySeconds) {
      published.push({ jobId, delaySeconds });
    },
  });

  const processing = await service.process("44444444-4444-4444-8444-444444444444");

  assert.deepEqual(processing, { continue: true, delaySeconds: 7 });
  assert.deepEqual(published, [{ jobId: "44444444-4444-4444-8444-444444444444", delaySeconds: 7 }]);
});

test("maintenance only performs bounded cleanup and never duplicates PROCESS_PREVIEW messages", async () => {
  const { database, calls } = createDatabase((sql) => {
    if (sql.includes("WITH removable AS")) {
      return result([{ id: "55555555-5555-4555-8555-555555555555" }]);
    }
    throw new Error(`Unexpected SQL: ${sql}`);
  });
  let published = 0;
  const service = new BracketPreviewService(database, {
    async sendProcessJob() {
      published += 1;
    },
  });

  assert.equal(await service.recoverAndCleanup(), 0);
  assert.equal(published, 0);
  assert.match(calls[0]?.sql ?? "", /LIMIT 25/);
  assert.match(calls[0]?.sql ?? "", /status = 'CONSUMED'/);
});

test("creates the approved bracket through the ported exact engine using the authenticated identity", async () => {
  const { database, calls } = createDatabase((sql) => {
    if (sql.includes("set_config('laje.request_user_id'")) return result();
    if (sql.includes("create_championship_bracket_from_preview_job")) {
      return result([{ edition_id: "66666666-6666-4666-8666-666666666666" }]);
    }
    throw new Error(`Unexpected SQL: ${sql}`);
  });
  const service = new BracketPreviewService(database, {
    async sendProcessJob() {},
  });

  const editionId = await service.createBracket(
    "77777777-7777-4777-8777-777777777777",
    "88888888-8888-4888-8888-888888888888",
    { competitions: [] },
    "99999999-9999-4999-8999-999999999999",
  );

  assert.equal(editionId, "66666666-6666-4666-8666-666666666666");
  assert.equal(calls[0]?.parameters[0], "99999999-9999-4999-8999-999999999999");
});
