import { assertControlledExecution, getMigrationConnection, streamDataExport } from "./shared.js";

assertControlledExecution("Data export");
if (process.stdout.isTTY) {
  throw new Error(
    "Data export must be piped directly to an approved importer, never to a terminal.",
  );
}
await streamDataExport(getMigrationConnection("source"), process.stdout);
