import {
  assertDestinationWriteAllowed,
  assertMigrationStorageBudget,
  getMigrationConnection,
  synchronizeData,
} from "./shared.js";

const mode = process.env.MIGRATION_SYNC_MODE;
if (mode !== "initial" && mode !== "final") {
  throw new Error("MIGRATION_SYNC_MODE must be initial or final.");
}
if (mode === "final" && !process.env.MIGRATION_WRITES_PAUSED_AT?.trim()) {
  throw new Error("Final synchronization requires MIGRATION_WRITES_PAUSED_AT.");
}

assertDestinationWriteAllowed("Data synchronization");
const source = getMigrationConnection("source");
const destination = getMigrationConnection("destination");
await assertMigrationStorageBudget(source, destination);
await synchronizeData(source, destination);
