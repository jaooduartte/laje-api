import assert from "node:assert/strict";
import test from "node:test";

import type { DatabaseConnection } from "../../src/database/types.js";
import {
  BracketPreviewService,
  buildBracketPreviewResult,
} from "../../src/modules/bracket-preview/bracket-preview.service.js";

function payload(slots: Array<Record<string, unknown>>) {
  return {
    match_numbering_mode: "COURT",
    competitions: [
      {
        sport_id: "11111111-1111-4111-8111-111111111111",
        naipe: "MASCULINO",
        division: null,
        groups: [
          {
            group_number: 1,
            team_ids: [
              "22222222-2222-4222-8222-222222222222",
              "33333333-3333-4333-8333-333333333333",
              "44444444-4444-4444-8444-444444444444",
            ],
          },
        ],
      },
    ],
    schedule_days: [
      {
        date: "2026-10-10",
        start_time: "08:00:00",
        end_time: "12:00:00",
        break_start_time: null,
        break_end_time: null,
      },
    ],
    structural_schedule_slots: slots,
  };
}

function slot(index: number) {
  const startHour = 8 + index;
  return {
    slot_key: `slot-${index}`,
    date: "2026-10-10",
    start_time: `${String(startHour).padStart(2, "0")}:00:00`,
    end_time: `${String(startHour).padStart(2, "0")}:50:00`,
    duration_minutes: 50,
    location_key: "gin",
    location_name: "Ginásio",
    court_key: "q1",
    court_name: "Quadra 1",
    competition_key: "11111111-1111-4111-8111-111111111111::MASCULINO::WITHOUT_DIVISION",
    sport_id: "11111111-1111-4111-8111-111111111111",
    naipe: "MASCULINO",
    division: null,
    phase: "GROUP_STAGE",
    phase_slot_number: index + 1,
    match_kind: "GROUP_STAGE",
    manual_final: false,
  };
}

test("AWS preview engine deterministically assigns group round-robin matches to structural slots", () => {
  const result = buildBracketPreviewResult(
    payload([slot(0), slot(1), slot(2)]),
    new Map([
      ["22222222-2222-4222-8222-222222222222", "A"],
      ["33333333-3333-4333-8333-333333333333", "B"],
      ["44444444-4444-4444-8444-444444444444", "C"],
    ]),
    new Map([["11111111-1111-4111-8111-111111111111", "Vôlei"]]),
  );

  assert.equal(result.ok, true);
  assert.equal(result.summary.total_matches, 3);
  assert.equal(result.summary.group_stage_matches, 3);
  assert.equal(result.summary.conflict_count, 0);
  assert.equal(result.days.length, 1);

  const day = result.days[0]!;
  const locations = day.locations as Array<Record<string, unknown>>;
  const courts = locations[0]!.courts as Array<Record<string, unknown>>;
  const entries = courts[0]!.entries as Array<Record<string, unknown>>;
  assert.deepEqual(
    entries.map((entry) => [entry.home_team_name, entry.away_team_name]),
    [
      ["A", "B"],
      ["A", "C"],
      ["B", "C"],
    ],
  );
});

test("AWS preview engine reports structural capacity gaps as blocking diagnostics", () => {
  const result = buildBracketPreviewResult(payload([slot(0), slot(1)]), new Map(), new Map());

  assert.equal(result.ok, false);
  assert.equal(result.summary.conflict_count, 1);
  assert.equal(result.diagnostics[0]?.code, "MISSING_GROUP_STAGE_SLOTS");
  assert.equal(result.diagnostics[0]?.severity, "ERROR");
});

function retryDatabase(attemptCount: number) {
  const calls: Array<{ sql: string; params: unknown[] | undefined }> = [];
  const database = {
    async query(sql: string, params?: unknown[]) {
      calls.push({ sql, params });
      if (sql.includes("SET status='INITIALIZING'")) {
        return { rows: [{ payload: {}, attemptCount }], rowCount: 1 };
      }
      return { rows: [], rowCount: 0 };
    },
  } as unknown as DatabaseConnection;
  return { database, calls };
}

test("preview worker returns retryable failures to QUEUED while SQS still has attempts", async () => {
  const { database, calls } = retryDatabase(1);
  const queue = { sendProcessJob: async () => undefined };
  const service = new BracketPreviewService(database, queue, 5);

  await assert.rejects(() => service.process("55555555-5555-4555-8555-555555555555"));

  const retryUpdate = calls.find((call) =>
    call.sql.includes("completed_at=CASE WHEN $3 = 'FAILED'"),
  );
  assert.ok(retryUpdate);
  assert.equal(retryUpdate.params?.[2], "QUEUED");
  assert.equal(retryUpdate.params?.[3], "Aguardando nova tentativa");
});

test("preview worker marks the job FAILED only after the configured retry limit", async () => {
  const { database, calls } = retryDatabase(5);
  const queue = { sendProcessJob: async () => undefined };
  const service = new BracketPreviewService(database, queue, 5);

  await assert.rejects(() => service.process("66666666-6666-4666-8666-666666666666"));

  const finalUpdate = calls.find((call) =>
    call.sql.includes("completed_at=CASE WHEN $3 = 'FAILED'"),
  );
  assert.ok(finalUpdate);
  assert.equal(finalUpdate.params?.[2], "FAILED");
  assert.equal(finalUpdate.params?.[3], "Falha após esgotar tentativas");
});

test("preview maintenance resets stale jobs without publishing duplicate SQS messages", async () => {
  let queuePublishes = 0;
  let queryCount = 0;
  const database = {
    async query() {
      queryCount += 1;
      if (queryCount === 1) {
        return {
          rows: [
            { id: "77777777-7777-4777-8777-777777777777" },
            { id: "88888888-8888-4888-8888-888888888888" },
          ],
          rowCount: 2,
        };
      }
      return { rows: [], rowCount: 0 };
    },
  } as unknown as DatabaseConnection;
  const service = new BracketPreviewService(
    database,
    {
      async sendProcessJob() {
        queuePublishes += 1;
      },
    },
    5,
  );

  assert.equal(await service.recoverAndCleanup(), 2);
  assert.equal(queuePublishes, 0);
});
