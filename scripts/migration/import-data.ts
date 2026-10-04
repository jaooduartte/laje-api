import {
  assertDestinationWriteAllowed,
  getMigrationConnection,
  importDataStream,
} from "./shared.js";

assertDestinationWriteAllowed("Data import");
if (process.stdin.isTTY) {
  throw new Error("Data import must receive a controlled pg_dump stream through standard input.");
}
const destination = getMigrationConnection("destination");
await importDataStream(process.stdin, destination);
