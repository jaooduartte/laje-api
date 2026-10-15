export type MigrationParityMode = "strict" | "rehearsal" | "final";

export interface FinalParityPreconditions {
  syncMode?: string;
  writesPausedAt?: string | undefined;
  expectedReservationRequestCount?: string | undefined;
  targetFrontend?: string | undefined;
}

export function getMigrationParityMode(
  value = process.env.MIGRATION_PARITY_MODE,
): MigrationParityMode {
  const normalized = value?.trim() || "strict";
  if (normalized === "strict" || normalized === "rehearsal" || normalized === "final") {
    return normalized;
  }

  throw new Error("MIGRATION_PARITY_MODE must be strict, rehearsal or final.");
}

export function assertParityModePreconditions(
  mode: MigrationParityMode,
  preconditions: FinalParityPreconditions = {},
): void {
  if (mode !== "final") return;

  const syncMode = preconditions.syncMode ?? process.env.MIGRATION_SYNC_MODE;
  const writesPausedAt = preconditions.writesPausedAt ?? process.env.MIGRATION_WRITES_PAUSED_AT;

  if (syncMode !== "final") {
    throw new Error("Final parity validation requires MIGRATION_SYNC_MODE=final.");
  }
  assertFinalCutoverCheckpoint({
    writesPausedAt,
    expectedReservationRequestCount:
      preconditions.expectedReservationRequestCount ??
      process.env.MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT,
  });
  assertFinalCutoverTarget(preconditions.targetFrontend);
}

export function parityFailureMessage(mode: MigrationParityMode): string {
  if (mode === "rehearsal") {
    return "Rehearsal parity validation detected differences. An active source may have drifted after synchronization; investigate source changes before classifying this as migration loss. Final cutover still requires strict parity after writes are paused.";
  }
  if (mode === "final") return "Final cutover parity validation failed.";
  return "Reservation parity validation failed.";
}

/**
 * A timestamp and reservation count are operator-supplied evidence, not proof
 * that writers are paused. The operational runbook requires independent freeze
 * confirmation before either final migration command runs.
 */
export function assertFinalCutoverCheckpoint(
  checkpoint: Pick<FinalParityPreconditions, "writesPausedAt" | "expectedReservationRequestCount">,
  now = new Date(),
): void {
  const pausedAt = checkpoint.writesPausedAt?.trim();
  if (!pausedAt) {
    throw new Error("Final cutover requires MIGRATION_WRITES_PAUSED_AT.");
  }
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})$/.test(pausedAt)) {
    throw new Error("MIGRATION_WRITES_PAUSED_AT must be an ISO 8601 timestamp with timezone.");
  }
  const parsedPausedAt = Date.parse(pausedAt);
  if (!Number.isFinite(parsedPausedAt) || parsedPausedAt > now.getTime()) {
    throw new Error("MIGRATION_WRITES_PAUSED_AT must be a valid timestamp in the past.");
  }
  const count = checkpoint.expectedReservationRequestCount?.trim();
  if (!count || !/^\d+$/.test(count) || !Number.isSafeInteger(Number(count))) {
    throw new Error(
      "Final cutover requires MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT as a non-negative integer captured after the write freeze.",
    );
  }
}

/**
 * Explicit scope gate for the final TCC snapshot. This operator-provided value
 * does not verify the connected Vercel project; the runbook requires that
 * independent verification before allowing migration writes.
 */
export function assertFinalCutoverTarget(target = process.env.MIGRATION_TARGET_FRONTEND): void {
  if (target?.trim() !== "laje-tcc") {
    throw new Error(
      "Final cutover requires MIGRATION_TARGET_FRONTEND=laje-tcc; the operational laje must remain on Supabase.",
    );
  }
}
