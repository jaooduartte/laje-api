import { calculateSchemaChecksum, getMigrationConnection } from "./shared.js";

const checksum = await calculateSchemaChecksum(getMigrationConnection("source"));
process.stdout.write(`${checksum}\n`);
