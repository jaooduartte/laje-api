import assert from "node:assert/strict";
import test from "node:test";
import { inspect } from "node:util";

import { createRedactedConfig } from "../../src/config/redacted-config.js";

test("createRedactedConfig redacts sensitive values in JSON and Node inspection", () => {
  const config = createRedactedConfig(
    {
      secret: "sensitive-value",
      visible: "public-value",
    },
    ["secret"] as const,
  );

  assert.equal(config.secret, "sensitive-value");
  assert.equal(config.visible, "public-value");

  const serialized = JSON.stringify(config);
  assert.match(serialized, /\[REDACTED\]/);
  assert.doesNotMatch(serialized, /sensitive-value/);
  assert.match(serialized, /public-value/);

  const inspected = inspect(config);
  assert.match(inspected, /\[REDACTED\]/);
  assert.doesNotMatch(inspected, /sensitive-value/);
  assert.match(inspected, /public-value/);
});
