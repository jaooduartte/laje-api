import { diffStructuralParity, executeQuery } from "./shared.js";
import type { MigrationConnection, StructuralParityRow } from "./shared.js";

export interface EnumParityRow {
  name: string;
  values: string[];
}

const enumParityQuery = `SELECT coalesce(
  json_agg(
    json_build_object('name', enum_name, 'values', enum_values)
    ORDER BY enum_name
  ),
  '[]'::json
)
FROM (
  SELECT enum_type.typname AS enum_name,
         array_agg(enum_value.enumlabel ORDER BY enum_value.enumsortorder) AS enum_values
  FROM pg_type AS enum_type
  JOIN pg_namespace AS namespace ON namespace.oid = enum_type.typnamespace
  JOIN pg_enum AS enum_value ON enum_value.enumtypid = enum_type.oid
  WHERE namespace.nspname = 'public'
  GROUP BY enum_type.typname
) AS enum_definitions;`;

export function parseEnumParity(output: string): EnumParityRow[] {
  const parsed = JSON.parse(output) as unknown;
  if (
    !Array.isArray(parsed) ||
    parsed.some((item) => {
      if (typeof item !== "object" || item === null) return true;
      const candidate = item as { name?: unknown; values?: unknown };
      return (
        typeof candidate.name !== "string" ||
        !Array.isArray(candidate.values) ||
        candidate.values.some((value) => typeof value !== "string")
      );
    })
  ) {
    throw new Error("Invalid enum parity output.");
  }
  return parsed as EnumParityRow[];
}

export async function getEnumParity(connection: MigrationConnection): Promise<EnumParityRow[]> {
  return parseEnumParity(
    await executeQuery(connection, "laje-migration-enum-parity", enumParityQuery),
  );
}

export function diffEnumParity(source: EnumParityRow[], destination: EnumParityRow[]): string[] {
  const sourceByName = new Map(source.map((item) => [item.name, item]));
  const destinationByName = new Map(destination.map((item) => [item.name, item]));
  const differences: string[] = [];

  for (const [name, item] of sourceByName) {
    const compared = destinationByName.get(name);
    if (!compared) {
      differences.push(`enum:${name} is missing from destination structure.`);
      continue;
    }
    if (JSON.stringify(item.values) !== JSON.stringify(compared.values)) {
      differences.push(`enum:${name} differs between source and destination structure.`);
    }
  }

  for (const name of destinationByName.keys()) {
    if (!sourceByName.has(name)) {
      differences.push(`enum:${name} is missing from source structure.`);
    }
  }

  return differences;
}

export function diffMigrationStructure(
  sourceStructure: StructuralParityRow[],
  destinationStructure: StructuralParityRow[],
  sourceEnums: EnumParityRow[],
  destinationEnums: EnumParityRow[],
): string[] {
  const differences = diffStructuralParity(sourceStructure, destinationStructure).filter(
    (difference) => !difference.startsWith("enum:"),
  );
  differences.push(...diffEnumParity(sourceEnums, destinationEnums));
  return differences;
}
