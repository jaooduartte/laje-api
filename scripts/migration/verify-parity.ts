import { diffMigrationStructure, getEnumParity } from "./enum-parity.js";
import {
  assertParityModePreconditions,
  getMigrationParityMode,
  parityFailureMessage,
} from "./parity-mode.js";
import {
  diffTableParity,
  getMigrationConnection,
  getReservationParity,
  getStructuralParity,
  getTableParity,
  reservationParityMatches,
} from "./shared.js";

const parityMode = getMigrationParityMode();
assertParityModePreconditions(parityMode);

const source = getMigrationConnection("source");
const destination = getMigrationConnection("destination");
const [
  sourceTables,
  destinationTables,
  sourceReservations,
  destinationReservations,
  sourceStructure,
  destinationStructure,
  sourceEnums,
  destinationEnums,
] = await Promise.all([
  getTableParity(source),
  getTableParity(destination),
  getReservationParity(source),
  getReservationParity(destination),
  getStructuralParity(source),
  getStructuralParity(destination),
  getEnumParity(source),
  getEnumParity(destination),
]);

const differences = diffTableParity(sourceTables, destinationTables);
differences.push(
  ...diffMigrationStructure(sourceStructure, destinationStructure, sourceEnums, destinationEnums),
);
const expectedReservationRequestCount = process.env.MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT;
const parsedExpectedReservationRequestCount = expectedReservationRequestCount
  ? Number(expectedReservationRequestCount)
  : undefined;

if (
  parsedExpectedReservationRequestCount !== undefined &&
  (!Number.isSafeInteger(parsedExpectedReservationRequestCount) ||
    parsedExpectedReservationRequestCount < 0)
) {
  throw new Error("MIGRATION_EXPECTED_RESERVATION_REQUEST_COUNT must be a non-negative integer.");
}

const reservationRequestCountMatches =
  parsedExpectedReservationRequestCount === undefined ||
  (sourceReservations.rowCount === parsedExpectedReservationRequestCount &&
    destinationReservations.rowCount === parsedExpectedReservationRequestCount);

if (
  differences.length > 0 ||
  !reservationParityMatches(sourceReservations, destinationReservations) ||
  !reservationRequestCountMatches
) {
  for (const difference of differences) process.stderr.write(`${difference}\n`);
  process.stderr.write(`${parityFailureMessage(parityMode)}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(
    JSON.stringify({
      enumTypesValidated: sourceEnums.length,
      parityMode,
      reservationRequests: {
        rowCount: destinationReservations.rowCount,
        statusDistribution: destinationReservations.statusDistribution,
      },
      tablesValidated: sourceTables.length,
      structuralObjectsValidated: sourceStructure.length,
    }) + "\n",
  );
}
