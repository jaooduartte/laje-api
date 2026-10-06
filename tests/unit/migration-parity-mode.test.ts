import assert from "node:assert/strict";
import test from "node:test";

import {
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
      }),
    /MIGRATION_SYNC_MODE=final/,
  );

  assert.throws(
    () => assertParityModePreconditions("final", { syncMode: "final", writesPausedAt: "" }),
    /MIGRATION_WRITES_PAUSED_AT/,
  );

  assert.doesNotThrow(() =>
    assertParityModePreconditions("final", {
      syncMode: "final",
      writesPausedAt: "2026-10-05T19:00:00Z",
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
