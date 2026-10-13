import assert from "node:assert/strict";
import test from "node:test";

import {
  assertFinalCutoverCheckpoint,
  assertParityModePreconditions,
  getMigrationParityMode,
  parityFailureMessage,
} from "../../scripts/migration/parity-mode.js";

test("parity mode defaults to strict and accepts explicit modes", () => {
  assert.equal(getMigrationParityMode(undefined), "strict");
  assert.equal(getMigrationParityMode(" rehearsal "), "rehearsal");
  assert.equal(getMigrationParityMode("final"), "final");
  assert.throws(() => getMigrationParityMode("invalid"), /MIGRATION_PARITY_MODE/);
});

test("final parity requires final sync mode and a write-freeze timestamp", () => {
  assert.throws(
    () =>
      assertParityModePreconditions("final", {
        syncMode: "initial",
        writesPausedAt: "2026-10-05T19:00:00Z",
        expectedReservationRequestCount: "41",
      }),
    /MIGRATION_SYNC_MODE=final/,
  );

  assert.throws(
    () => assertParityModePreconditions("final", { syncMode: "final", writesPausedAt: "", expectedReservationRequestCount: "41" }),
    /MIGRATION_WRITES_PAUSED_AT/,
  );

  assert.doesNotThrow(() =>
    assertParityModePreconditions("final", {
      syncMode: "final",
      writesPausedAt: "2026-10-05T19:00:00Z",
      expectedReservationRequestCount: "41",
    }),
  );
});

test("rehearsal mode keeps parity strict but explains active-source drift", () => {
  assert.doesNotThrow(() => assertParityModePreconditions("rehearsal"));
  assert.match(parityFailureMessage("rehearsal"), /active source may have drifted/i);
  assert.match(parityFailureMessage("rehearsal"), /Final cutover still requires strict parity/);
  assert.equal(parityFailureMessage("final"), "Final cutover parity validation failed.");
  assert.equal(parityFailureMessage("strict"), "Reservation parity validation failed.");
});

test("final cutover rejects missing counts and invalid write-freeze timestamps", () => {
  const today = new Date("2026-10-13T18:20:00Z");
  const base = {
    writesPausedAt: "2026-10-13T18:00:00Z",
    expectedReservationRequestCount: "41",
  };
  assert.doesNotThrow(() => assertFinalCutoverCheckpoint(base, today));
  assert.doesNotThrow(() =>
    assertFinalCutoverCheckpoint(
      { writesPausedAt: "2026-10-13T15:00:00-03:00", expectedReservationRequestCount: "0" },
      today,
    ),
  );
  for (const value of ["", "  ", "forty-one", "-1", "1.5", "9007199254740992"]) {
    assert.throws(
      () => assertFinalCutoverCheckpoint({ ...base, expectedReservationRequestCount: value }, today),
      /MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT/,
    );
  }
  for (const value of [
    "",
    "yesterday",
    "2026-10-13",
    "2026-10-13T18:00:00",
    "2026-10-13T18:21:00Z",
    "2026-13-13T18:00:00Z",
  ]) {
    assert.throws(
      () => assertFinalCutoverCheckpoint({ ...base, writesPausedAt: value }, today),
      /MIGRATION_WRITES_PAUSED_AT/,
    );
  }
});
test("final parity refuses an unrecorded reservation count", () => {
  assert.throws(
    () =>
      assertParityModePreconditions("final", {
        syncMode: "final",
        writesPausedAt: "2026-10-13T17:00:00Z",
        expectedReservationRequestCount: "",
      }),
    /MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT/,
  );
});
