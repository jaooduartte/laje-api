import assert from "node:assert/strict";
import test from "node:test";

import {
  diffEnumParity,
  diffMigrationStructure,
  parseEnumParity,
} from "../../scripts/migration/enum-parity.js";
import type { EnumParityRow } from "../../scripts/migration/enum-parity.js";
import type { StructuralParityRow } from "../../scripts/migration/shared.js";

const championshipStatusValues = [
  "PLANNING",
  "UPCOMING",
  "REVIEW",
  "IN_PROGRESS",
  "FINISHED",
];

test("enum parity ignores internal enum sort hashes when logical order matches", () => {
  const sourceStructure: StructuralParityRow[] = championshipStatusValues.map((value, index) => ({
    kind: "enum",
    name: `championship_status.${value}`,
    checksum: `source-${index}`,
  }));
  const destinationStructure: StructuralParityRow[] = championshipStatusValues.map(
    (value, index) => ({
      kind: "enum",
      name: `championship_status.${value}`,
      checksum: `destination-${index}`,
    }),
  );
  const sourceEnums: EnumParityRow[] = [
    { name: "championship_status", values: championshipStatusValues },
  ];
  const destinationEnums: EnumParityRow[] = [
    { name: "championship_status", values: [...championshipStatusValues] },
  ];

  assert.deepEqual(
    diffMigrationStructure(sourceStructure, destinationStructure, sourceEnums, destinationEnums),
    [],
  );
});

test("enum parity detects a semantic ordering difference", () => {
  const source: EnumParityRow[] = [
    { name: "championship_status", values: championshipStatusValues },
  ];
  const destination: EnumParityRow[] = [
    {
      name: "championship_status",
      values: ["UPCOMING", "PLANNING", "REVIEW", "IN_PROGRESS", "FINISHED"],
    },
  ];

  assert.deepEqual(diffEnumParity(source, destination), [
    "enum:championship_status differs between source and destination structure.",
  ]);
});

test("enum parity parser validates ordered enum values", () => {
  assert.deepEqual(
    parseEnumParity(
      JSON.stringify([{ name: "championship_status", values: championshipStatusValues }]),
    ),
    [{ name: "championship_status", values: championshipStatusValues }],
  );

  assert.throws(
    () => parseEnumParity(JSON.stringify([{ name: "championship_status", values: [1, 2] }])),
    /Invalid enum parity output/,
  );
});
