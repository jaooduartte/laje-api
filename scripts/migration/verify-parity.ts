import {
  diffTableParity,
  getMigrationConnection,
  getReservationParity,
  getTableParity,
  reservationParityMatches,
} from "./shared.js";

const source = getMigrationConnection("source");
const destination = getMigrationConnection("destination");
const [sourceTables, destinationTables, sourceReservations, destinationReservations] =
  await Promise.all([
    getTableParity(source),
    getTableParity(destination),
    getReservationParity(source),
    getReservationParity(destination),
  ]);

const differences = diffTableParity(sourceTables, destinationTables);
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
  process.stderr.write("Reservation parity validation failed.\n");
  process.exitCode = 1;
} else {
  process.stdout.write(
    JSON.stringify({
      reservationRequests: {
        rowCount: destinationReservations.rowCount,
        statusDistribution: destinationReservations.statusDistribution,
      },
      tablesValidated: sourceTables.length,
    }) + "\n",
  );
}
