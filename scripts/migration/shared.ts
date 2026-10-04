import { createHash } from "node:crypto";
import { spawn } from "node:child_process";
import type { ChildProcessWithoutNullStreams, SpawnOptionsWithoutStdio } from "node:child_process";

export type MigrationConnectionName = "source" | "destination";

export interface MigrationConnection {
  database: string;
  host: string;
  password: string | undefined;
  port: string;
  sslMode: string;
  sslRootCert: string | undefined;
  user: string;
}

export interface ParityRow {
  checksum: string;
  rowCount: number;
  tableName: string;
}

export interface ReservationParity {
  approvedEventForeignKeyViolations: number;
  dataChecksum: string;
  idChecksum: string;
  rowCount: number;
  statusDistribution: Record<string, number>;
  teamForeignKeyViolations: number;
}

const dataDumpArguments = [
  "--data-only",
  "--format=plain",
  "--no-owner",
  "--no-privileges",
  "--schema=public",
];

function requiredEnvironment(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

function optionalEnvironment(name: string): string | undefined {
  const value = process.env[name]?.trim();
  return value || undefined;
}

function connectionVariable(name: MigrationConnectionName): string {
  return `MIGRATION_${name.toUpperCase()}_DATABASE_URL`;
}

function rootCertificateVariable(name: MigrationConnectionName): string {
  return `MIGRATION_${name.toUpperCase()}_SSL_ROOT_CERT`;
}

export function getMigrationConnection(name: MigrationConnectionName): MigrationConnection {
  const variable = connectionVariable(name);
  const rawUrl = requiredEnvironment(variable);
  const parsed = new URL(rawUrl);
  if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
    throw new Error(`${variable} must use postgres:// or postgresql://.`);
  }

  const database = decodeURIComponent(parsed.pathname.replace(/^\//, ""));
  if (!parsed.hostname || !database || !parsed.username) {
    throw new Error(`${variable} must include host, database and username.`);
  }

  return {
    database,
    host: parsed.hostname,
    password: parsed.password ? decodeURIComponent(parsed.password) : undefined,
    port: parsed.port || "5432",
    sslMode: parsed.searchParams.get("sslmode") || "require",
    sslRootCert:
      parsed.searchParams.get("sslrootcert") || optionalEnvironment(rootCertificateVariable(name)),
    user: decodeURIComponent(parsed.username),
  };
}

export function commandEnvironment(
  connection: MigrationConnection,
  applicationName: string,
): NodeJS.ProcessEnv {
  const environment: NodeJS.ProcessEnv = {
    ...process.env,
    PGAPPNAME: applicationName,
    PGDATABASE: connection.database,
    PGHOST: connection.host,
    PGPASSWORD: connection.password,
    PGPORT: connection.port,
    PGSSLMODE: connection.sslMode,
    PGUSER: connection.user,
  };
  if (connection.sslRootCert) environment.PGSSLROOTCERT = connection.sslRootCert;
  return environment;
}

export function assertControlledExecution(action: string): void {
  if (process.env.MIGRATION_EXECUTION_CONTEXT !== "controlled") {
    throw new Error(`${action} requires MIGRATION_EXECUTION_CONTEXT=controlled.`);
  }
}

export function assertDestinationWriteAllowed(action: string): void {
  assertControlledExecution(action);
  if (process.env.MIGRATION_ALLOW_DESTINATION_WRITE !== "true") {
    throw new Error(`${action} requires MIGRATION_ALLOW_DESTINATION_WRITE=true.`);
  }
}

function commandError(command: string, code: number | null, stderr: string): Error {
  const detail = stderr.trim();
  return new Error(
    `${command} exited with code ${code ?? "unknown"}.${detail ? ` ${detail}` : ""}`,
  );
}

function startCommand(
  command: string,
  argumentsList: string[],
  environment: NodeJS.ProcessEnv,
): ChildProcessWithoutNullStreams {
  const options: SpawnOptionsWithoutStdio = {
    env: environment,
    stdio: ["pipe", "pipe", "pipe"],
  };
  return spawn(command, argumentsList, options);
}

async function waitForCommand(
  command: string,
  process: ChildProcessWithoutNullStreams,
): Promise<void> {
  const stderr: Buffer[] = [];
  process.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
  await new Promise<void>((resolve, reject) => {
    process.once("error", reject);
    process.once("close", (code) => {
      if (code === 0) resolve();
      else reject(commandError(command, code, Buffer.concat(stderr).toString("utf8")));
    });
  });
}

export async function executeQuery(
  connection: MigrationConnection,
  applicationName: string,
  query: string,
): Promise<string> {
  const process = startCommand(
    "psql",
    [
      "--no-psqlrc",
      "--quiet",
      "--tuples-only",
      "--no-align",
      "--set=ON_ERROR_STOP=1",
      "--command",
      query,
    ],
    commandEnvironment(connection, applicationName),
  );
  process.stdin.end();

  const output: Buffer[] = [];
  process.stdout.on("data", (chunk: Buffer) => output.push(chunk));
  await waitForCommand("psql", process);
  return Buffer.concat(output).toString("utf8").trim();
}

export async function streamDataExport(
  connection: MigrationConnection,
  destination: NodeJS.WritableStream,
): Promise<void> {
  const process = startCommand(
    "pg_dump",
    dataDumpArguments,
    commandEnvironment(connection, "laje-migration-export-data"),
  );
  process.stdin.end();
  process.stdout.pipe(destination);
  await waitForCommand("pg_dump", process);
}

export async function importDataStream(
  source: NodeJS.ReadableStream,
  connection: MigrationConnection,
): Promise<void> {
  const process = startCommand(
    "psql",
    ["--no-psqlrc", "--quiet", "--set=ON_ERROR_STOP=1", "--single-transaction"],
    commandEnvironment(connection, "laje-migration-import-data"),
  );
  source.pipe(process.stdin);
  await waitForCommand("psql", process);
}

export async function synchronizeData(
  source: MigrationConnection,
  destination: MigrationConnection,
): Promise<void> {
  const sourceProcess = startCommand(
    "pg_dump",
    dataDumpArguments,
    commandEnvironment(source, "laje-migration-sync-export"),
  );
  const destinationProcess = startCommand(
    "psql",
    ["--no-psqlrc", "--quiet", "--set=ON_ERROR_STOP=1", "--single-transaction"],
    commandEnvironment(destination, "laje-migration-sync-import"),
  );
  sourceProcess.stdin.end();
  sourceProcess.stdout.pipe(destinationProcess.stdin);
  await Promise.all([
    waitForCommand("pg_dump", sourceProcess),
    waitForCommand("psql", destinationProcess),
  ]);
}

export async function truncateDestinationPublicSchema(
  connection: MigrationConnection,
): Promise<void> {
  await executeQuery(
    connection,
    "laje-migration-truncate",
    `DO $$
     DECLARE table_list text;
     BEGIN
       SELECT string_agg(format('%I.%I', schemaname, tablename), ', ' ORDER BY tablename)
         INTO table_list
       FROM pg_tables
       WHERE schemaname = 'public';
       IF table_list IS NULL THEN
         RAISE EXCEPTION 'No public tables were found in the destination database.';
       END IF;
       EXECUTE 'TRUNCATE TABLE ' || table_list || ' RESTART IDENTITY CASCADE';
     END
     $$;`,
  );
}

export async function prepareDedicatedAuthentication(
  connection: MigrationConnection,
): Promise<void> {
  await executeQuery(
    connection,
    "laje-migration-auth-reset",
    `DELETE FROM public.admin_auth_sessions;
     DELETE FROM public.admin_auth_accounts;
     UPDATE public.admin_user_profiles
     SET password_status = 'PENDING'::public.admin_user_password_status,
         updated_at = now();`,
  );
}

export async function calculateSchemaChecksum(connection: MigrationConnection): Promise<string> {
  const process = startCommand(
    "pg_dump",
    ["--schema-only", "--no-owner", "--no-privileges", "--schema=public"],
    commandEnvironment(connection, "laje-migration-export-schema"),
  );
  process.stdin.end();

  const hash = createHash("sha256");
  process.stdout.on("data", (chunk: Buffer) => hash.update(chunk));
  await waitForCommand("pg_dump", process);
  return hash.digest("hex");
}

const tableParityQuery = `CREATE OR REPLACE FUNCTION pg_temp.laje_migration_table_parity()
RETURNS TABLE(table_name text, row_count bigint, checksum text)
LANGUAGE plpgsql
AS $$
DECLARE item record;
BEGIN
  FOR item IN
    SELECT c.relname AS table_name,
           string_agg(format('t.%I::text', a.attname), ', ' ORDER BY key_columns.ordinality) AS key_values,
           string_agg(format('t.%I', a.attname), ', ' ORDER BY key_columns.ordinality) AS key_order
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_constraint constraint_record ON constraint_record.conrelid = c.oid AND constraint_record.contype = 'p'
    JOIN unnest(constraint_record.conkey) WITH ORDINALITY AS key_columns(attribute_number, ordinality) ON true
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = key_columns.attribute_number
    WHERE n.nspname = 'public' AND c.relkind = 'r'
    GROUP BY c.relname
    ORDER BY c.relname
  LOOP
    RETURN QUERY EXECUTE format(
      'SELECT %L, count(*), md5(coalesce(string_agg(concat_ws(''|'', %s), '','' ORDER BY %s), '''')) FROM public.%I AS t',
      item.table_name,
      item.key_values,
      item.key_order,
      item.table_name
    );
  END LOOP;
END
$$;
SELECT table_name, row_count, checksum
FROM pg_temp.laje_migration_table_parity()
ORDER BY table_name;`;

const reservationParityQuery = `SELECT json_build_object(
  'rowCount', (SELECT count(*) FROM public.league_event_reservation_requests),
  'idChecksum', (
    SELECT md5(coalesce(string_agg(id::text, ',' ORDER BY id), ''))
    FROM public.league_event_reservation_requests
  ),
  'dataChecksum', (
    SELECT md5(coalesce(string_agg(
      md5(jsonb_build_array(
        id,
        team_id,
        event_name,
        event_type,
        event_date,
        requester_name,
        requester_email,
        status,
        approved_league_event_id,
        review_notes,
        reviewed_at,
        reviewed_by,
        created_at,
        updated_at
      )::text),
      ',' ORDER BY id
    ), ''))
    FROM public.league_event_reservation_requests
  ),
  'statusDistribution', (
    SELECT coalesce(json_object_agg(status, row_count ORDER BY status), '{}'::json)
    FROM (
      SELECT status::text AS status, count(*)::integer AS row_count
      FROM public.league_event_reservation_requests
      GROUP BY status
    ) AS status_totals
  ),
  'teamForeignKeyViolations', (
    SELECT count(*)
    FROM public.league_event_reservation_requests AS request
    LEFT JOIN public.teams AS team ON team.id = request.team_id
    WHERE team.id IS NULL
  ),
  'approvedEventForeignKeyViolations', (
    SELECT count(*)
    FROM public.league_event_reservation_requests AS request
    LEFT JOIN public.league_events AS event ON event.id = request.approved_league_event_id
    WHERE request.approved_league_event_id IS NOT NULL AND event.id IS NULL
  )
);`;

export function parseParityRows(output: string): ParityRow[] {
  if (!output) return [];
  return output.split("\n").map((line) => {
    const [tableName, rawCount, checksum] = line.split("|");
    if (!tableName || !rawCount || !checksum || !/^\d+$/.test(rawCount)) {
      throw new Error("Invalid table parity output.");
    }
    return { checksum, rowCount: Number(rawCount), tableName };
  });
}

export function parseReservationParity(output: string): ReservationParity {
  const parsed = JSON.parse(output) as {
    approvedEventForeignKeyViolations: number;
    dataChecksum: string;
    idChecksum: string;
    rowCount: number;
    statusDistribution: Record<string, number>;
    teamForeignKeyViolations: number;
  };
  return {
    approvedEventForeignKeyViolations: parsed.approvedEventForeignKeyViolations,
    dataChecksum: parsed.dataChecksum,
    idChecksum: parsed.idChecksum,
    rowCount: parsed.rowCount,
    statusDistribution: parsed.statusDistribution,
    teamForeignKeyViolations: parsed.teamForeignKeyViolations,
  };
}

export async function getTableParity(connection: MigrationConnection): Promise<ParityRow[]> {
  return parseParityRows(
    await executeQuery(connection, "laje-migration-table-parity", tableParityQuery),
  );
}

export async function getReservationParity(
  connection: MigrationConnection,
): Promise<ReservationParity> {
  return parseReservationParity(
    await executeQuery(connection, "laje-migration-reservation-parity", reservationParityQuery),
  );
}

export function diffTableParity(source: ParityRow[], destination: ParityRow[]): string[] {
  const destinationByTable = new Map(destination.map((item) => [item.tableName, item]));
  const differences: string[] = [];
  for (const item of source) {
    const compared = destinationByTable.get(item.tableName);
    if (!compared) {
      differences.push(`${item.tableName} is missing from destination parity output.`);
      continue;
    }
    if (item.rowCount !== compared.rowCount || item.checksum !== compared.checksum) {
      differences.push(`${item.tableName} differs between source and destination.`);
    }
  }
  for (const item of destination) {
    if (!source.some((sourceItem) => sourceItem.tableName === item.tableName)) {
      differences.push(`${item.tableName} is missing from source parity output.`);
    }
  }
  return differences;
}

export function reservationParityMatches(
  source: ReservationParity,
  destination: ReservationParity,
): boolean {
  return (
    source.rowCount === destination.rowCount &&
    source.idChecksum === destination.idChecksum &&
    source.dataChecksum === destination.dataChecksum &&
    sameStatusDistribution(source.statusDistribution, destination.statusDistribution) &&
    destination.teamForeignKeyViolations === 0 &&
    destination.approvedEventForeignKeyViolations === 0
  );
}

function sameStatusDistribution(
  source: Record<string, number>,
  destination: Record<string, number>,
): boolean {
  const sourceEntries = Object.entries(source).sort(([left], [right]) => left.localeCompare(right));
  const destinationEntries = Object.entries(destination).sort(([left], [right]) =>
    left.localeCompare(right),
  );
  return JSON.stringify(sourceEntries) === JSON.stringify(destinationEntries);
}
