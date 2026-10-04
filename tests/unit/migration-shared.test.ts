import assert from "node:assert/strict";
import test from "node:test";

import {
  diffTableParity,
  parseParityRows,
  parseReservationParity,
  reservationParityMatches,
} from "../../scripts/migration/shared.js";

test("table parity parser accepts aggregate output without row values", () => {
  assert.deepEqual(parseParityRows("teams|2|abc\nsports|3|def"), [
    { tableName: "teams", rowCount: 2, checksum: "abc" },
    { tableName: "sports", rowCount: 3, checksum: "def" },
  ]);
});

test("table parity differences include missing and changed tables", () => {
  const differences = diffTableParity(
    [{ tableName: "teams", rowCount: 2, checksum: "source" }],
    [
      { tableName: "teams", rowCount: 3, checksum: "destination" },
      { tableName: "sports", rowCount: 1, checksum: "other" },
    ],
  );

  assert.deepEqual(differences, [
    "teams differs between source and destination.",
    "sports is missing from source parity output.",
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
