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
  dataChecksum: string;
  rowCount: number;
  tableName: string;
}

export interface StructuralParityRow {
  checksum: string;
  kind: string;
  name: string;
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

function commandError(command: string, code: number | null): Error {
  return new Error(`${command} exited with code ${code ?? "unknown"}.`);
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
  process.stderr.resume();
  await new Promise<void>((resolve, reject) => {
    process.once("error", reject);
    process.once("close", (code) => {
      if (code === 0) resolve();
      else reject(commandError(command, code));
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
    [
      "--no-psqlrc",
      "--quiet",
      "--set=ON_ERROR_STOP=1",
      "--single-transaction",
      "--file=-",
      "--command",
      resetAuthenticationQuery,
    ],
    commandEnvironment(connection, "laje-migration-import-data"),
  );
  source.pipe(process.stdin);
  await waitForCommand("psql", process);
}

const truncateDestinationQuery = `DO $$
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
$$;`;

const resetAuthenticationQuery = `DELETE FROM public.admin_auth_sessions;
DELETE FROM public.admin_auth_accounts;
UPDATE public.admin_user_profiles
SET password_status = 'PENDING'::public.admin_user_password_status,
    updated_at = now();`;

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
    [
      "--no-psqlrc",
      "--quiet",
      "--set=ON_ERROR_STOP=1",
      "--single-transaction",
      "--command",
      truncateDestinationQuery,
      "--file=-",
      "--command",
      resetAuthenticationQuery,
    ],
    commandEnvironment(destination, "laje-migration-sync-import"),
  );
  sourceProcess.stdin.end();
  const sourceCompletion = waitForCommand("pg_dump", sourceProcess);
  const destinationCompletion = waitForCommand("psql", destinationProcess);
  void destinationCompletion.catch(() => undefined);
  const streamCompletion = new Promise<void>((resolve, reject) => {
    sourceProcess.stdout.once("end", resolve);
    sourceProcess.stdout.once("error", reject);
    destinationProcess.stdin.on("error", reject);
    sourceProcess.stdout.pipe(destinationProcess.stdin, { end: false });
  });

  try {
    await Promise.all([sourceCompletion, streamCompletion]);
    destinationProcess.stdin.end();
    await destinationCompletion;
  } catch (error) {
    sourceProcess.kill();
    if (!destinationProcess.stdin.destroyed) {
      destinationProcess.stdin.write("SELECT 1 / 0;\n");
      destinationProcess.stdin.end();
    }
    await Promise.allSettled([sourceCompletion, destinationCompletion]);
    throw error;
  }
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
RETURNS TABLE(table_name text, row_count bigint, checksum text, data_checksum text)
LANGUAGE plpgsql
AS $$
DECLARE item record;
BEGIN
  FOR item IN
    SELECT c.relname AS table_name,
           string_agg(format('t.%I::text', a.attname), ', ' ORDER BY key_columns.ordinality) AS key_values,
           string_agg(format('t.%I', a.attname), ', ' ORDER BY key_columns.ordinality) AS key_order,
           CASE WHEN c.relname = 'admin_user_profiles'
             THEN 'to_jsonb(t) - ''password_status'' - ''updated_at'''
             ELSE 'to_jsonb(t)'
           END AS row_value
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_constraint constraint_record ON constraint_record.conrelid = c.oid AND constraint_record.contype = 'p'
    JOIN unnest(constraint_record.conkey) WITH ORDINALITY AS key_columns(attribute_number, ordinality) ON true
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = key_columns.attribute_number
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND c.relname NOT IN ('admin_auth_accounts', 'admin_auth_sessions')
    GROUP BY c.relname
    ORDER BY c.relname
  LOOP
    RETURN QUERY EXECUTE format(
      'SELECT %L, count(*), md5(coalesce(string_agg(concat_ws(''|'', %s), '','' ORDER BY %s), '''')), md5(coalesce(string_agg(md5((%s)::text), '','' ORDER BY %s), '''')) FROM public.%I AS t',
      item.table_name,
      item.key_values,
      item.key_order,
      item.row_value,
      item.key_order,
      item.table_name
    );
  END LOOP;
END
$$;
SELECT table_name, row_count, checksum, data_checksum
FROM pg_temp.laje_migration_table_parity()
ORDER BY table_name;`;

const structuralParityQuery = `SET search_path = public, pg_catalog;
WITH objects AS (
  SELECT 'column'::text AS kind,
         relation.relname || '.' || attribute.attname AS object_name,
         concat_ws('|', format_type(attribute.atttypid, attribute.atttypmod),
                   attribute.attnotnull::text,
                   coalesce(pg_get_expr(default_value.adbin, default_value.adrelid), ''),
                   attribute.attgenerated::text,
                   attribute.attidentity::text) AS definition
  FROM pg_class AS relation
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  JOIN pg_attribute AS attribute ON attribute.attrelid = relation.oid
  LEFT JOIN pg_attrdef AS default_value
    ON default_value.adrelid = relation.oid AND default_value.adnum = attribute.attnum
  WHERE namespace.nspname = 'public' AND relation.relkind = 'r'
    AND relation.relname NOT IN ('admin_auth_accounts', 'admin_auth_sessions')
    AND attribute.attnum > 0 AND NOT attribute.attisdropped
  UNION ALL
  SELECT 'enum', enum_type.typname || '.' || enum_value.enumlabel,
         enum_value.enumsortorder::text
  FROM pg_type AS enum_type
  JOIN pg_namespace AS namespace ON namespace.oid = enum_type.typnamespace
  JOIN pg_enum AS enum_value ON enum_value.enumtypid = enum_type.oid
  WHERE namespace.nspname = 'public'
  UNION ALL
  SELECT 'constraint', relation.relname || '.' || constraint_record.conname,
         constraint_record.contype::text || '|' || pg_get_constraintdef(constraint_record.oid)
  FROM pg_constraint AS constraint_record
  JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  LEFT JOIN pg_class AS referenced_relation ON referenced_relation.oid = constraint_record.confrelid
  LEFT JOIN pg_namespace AS referenced_namespace
    ON referenced_namespace.oid = referenced_relation.relnamespace
  WHERE namespace.nspname = 'public' AND relation.relkind = 'r'
    AND relation.relname NOT IN ('admin_auth_accounts', 'admin_auth_sessions')
    AND (constraint_record.contype <> 'f' OR referenced_namespace.nspname = 'public')
  UNION ALL
  SELECT 'index', relation.relname || '.' || index_relation.relname,
         pg_get_indexdef(index_record.indexrelid)
  FROM pg_index AS index_record
  JOIN pg_class AS relation ON relation.oid = index_record.indrelid
  JOIN pg_class AS index_relation ON index_relation.oid = index_record.indexrelid
  JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
  WHERE namespace.nspname = 'public' AND relation.relkind = 'r'
    AND relation.relname NOT IN ('admin_auth_accounts', 'admin_auth_sessions')
)
SELECT coalesce(json_agg(json_build_object(
  'kind', kind, 'name', object_name, 'checksum', md5(definition)
) ORDER BY kind, object_name), '[]'::json)
FROM objects;`;

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
    const [tableName, rawCount, checksum, dataChecksum] = line.split("|");
    if (!tableName || !rawCount || !checksum || !dataChecksum || !/^\d+$/.test(rawCount)) {
      throw new Error("Invalid table parity output.");
    }
    return { checksum, dataChecksum, rowCount: Number(rawCount), tableName };
  });
}

export function parseStructuralParity(output: string): StructuralParityRow[] {
  const parsed = JSON.parse(output) as StructuralParityRow[];
  if (
    !Array.isArray(parsed) ||
    parsed.some(
      (item) =>
        typeof item.kind !== "string" ||
        typeof item.name !== "string" ||
        typeof item.checksum !== "string",
    )
  ) {
    throw new Error("Invalid structural parity output.");
  }
  return parsed;
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

export async function getStructuralParity(
  connection: MigrationConnection,
): Promise<StructuralParityRow[]> {
  return parseStructuralParity(
    await executeQuery(connection, "laje-migration-structural-parity", structuralParityQuery),
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
    if (
      item.rowCount !== compared.rowCount ||
      item.checksum !== compared.checksum ||
      item.dataChecksum !== compared.dataChecksum
    ) {
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

export function diffStructuralParity(
  source: StructuralParityRow[],
  destination: StructuralParityRow[],
): string[] {
  const sourceByName = new Map(source.map((item) => [`${item.kind}:${item.name}`, item]));
  const destinationByName = new Map(destination.map((item) => [`${item.kind}:${item.name}`, item]));
  const differences: string[] = [];
  for (const [name, item] of sourceByName) {
    const compared = destinationByName.get(name);
    if (!compared) differences.push(`${name} is missing from destination structure.`);
    else if (item.checksum !== compared.checksum) {
      differences.push(`${name} differs between source and destination structure.`);
    }
  }
  for (const name of destinationByName.keys()) {
    if (!sourceByName.has(name)) differences.push(`${name} is missing from source structure.`);
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
