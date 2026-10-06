import assert from "node:assert/strict";
import test from "node:test";

import {
  assertDistinctDatabases,
  diffTableParity,
  diffStructuralParity,
  parseParityRows,
  parseReservationParity,
  parseStructuralParity,
  reservationParityMatches,
} from "../../scripts/migration/shared.js";
import type { MigrationConnection } from "../../scripts/migration/shared.js";

test("migration refuses to synchronize a database with itself before connecting", async () => {
  const connection: MigrationConnection = {
    database: "laje_source",
    host: "localhost",
    password: undefined,
    port: "5432",
    sslMode: "disable",
    sslRootCert: undefined,
    user: "postgres",
  };

  await assert.rejects(
    assertDistinctDatabases(connection, { ...connection, host: "LOCALHOST" }),
    /Source and destination must be distinct databases/,
  );
});

test("table parity parser accepts aggregate output without row values", () => {
  assert.deepEqual(parseParityRows("teams|2|abc|rows1\nsports|3|def|rows2"), [
    { tableName: "teams", rowCount: 2, checksum: "abc", dataChecksum: "rows1" },
    { tableName: "sports", rowCount: 3, checksum: "def", dataChecksum: "rows2" },
  ]);
});

test("table parity differences include missing and changed tables", () => {
  const differences = diffTableParity(
    [{ tableName: "teams", rowCount: 2, checksum: "source", dataChecksum: "rows1" }],
    [
      { tableName: "teams", rowCount: 3, checksum: "destination", dataChecksum: "rows2" },
      { tableName: "sports", rowCount: 1, checksum: "other", dataChecksum: "rows3" },
    ],
  );

  assert.deepEqual(differences, [
    "teams differs between source and destination.",
    "sports is missing from source parity output.",
  ]);
});

test("table parity detects changed row data when primary keys match", () => {
  assert.deepEqual(
    diffTableParity(
      [{ tableName: "teams", rowCount: 1, checksum: "ids", dataChecksum: "source" }],
      [{ tableName: "teams", rowCount: 1, checksum: "ids", dataChecksum: "destination" }],
    ),
    ["teams differs between source and destination."],
  );
});

test("structural parity detects missing and changed schema objects", () => {
  const source = parseStructuralParity(
    JSON.stringify([
      { kind: "column", name: "teams.name", checksum: "name" },
      { kind: "index", name: "teams.teams_pkey", checksum: "index" },
    ]),
  );
  const destination = parseStructuralParity(
    JSON.stringify([{ kind: "column", name: "teams.name", checksum: "changed" }]),
  );

  assert.deepEqual(diffStructuralParity(source, destination), [
    "column:teams.name differs between source and destination structure.",
    "index:teams.teams_pkey is missing from destination structure.",
  ]);
});

test("reservation parity requires matching aggregates and destination foreign keys", () => {
  const source = parseReservationParity(
    JSON.stringify({
      rowCount: 39,
      idChecksum: "ids",
      dataChecksum: "data",
      statusDistribution: { PENDING: 39 },
      teamForeignKeyViolations: 0,
      approvedEventForeignKeyViolations: 0,
    }),
  );
  const destination = parseReservationParity(
    JSON.stringify({
      rowCount: 39,
      idChecksum: "ids",
      dataChecksum: "data",
      statusDistribution: { PENDING: 39 },
      teamForeignKeyViolations: 0,
      approvedEventForeignKeyViolations: 0,
    }),
  );

  assert.equal(reservationParityMatches(source, destination), true);
  assert.equal(
    reservationParityMatches(source, { ...destination, teamForeignKeyViolations: 1 }),
    false,
  );
});
