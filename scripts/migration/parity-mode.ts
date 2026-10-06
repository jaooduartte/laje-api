export type MigrationParityMode = "strict" | "rehearsal" | "final";

export interface FinalParityPreconditions {
  syncMode?: string;
  writesPausedAt?: string;
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
  const writesPausedAt =
    preconditions.writesPausedAt ?? process.env.MIGRATION_WRITES_PAUSED_AT;

  if (syncMode !== "final") {
    throw new Error("Final parity validation requires MIGRATION_SYNC_MODE=final.");
  }
  if (!writesPausedAt?.trim()) {
    throw new Error("Final parity validation requires MIGRATION_WRITES_PAUSED_AT.");
  }
}

export function parityFailureMessage(mode: MigrationParityMode): string {
  if (mode === "rehearsal") {
    return "Rehearsal parity validation detected differences. An active source may have drifted after synchronization; investigate source changes before classifying this as migration loss. Final cutover still requires strict parity after writes are paused.";
  }
  if (mode === "final") return "Final cutover parity validation failed.";
  return "Reservation parity validation failed.";
}
