import assert from "node:assert/strict";
import test from "node:test";

import { readBearerToken } from "../../src/modules/auth/auth.schema.js";

test("reads Bearer authentication headers with linear-time parsing", () => {
  assert.equal(readBearerToken("Bearer abc.def.ghi"), "abc.def.ghi");
  assert.equal(readBearerToken("bEaReR    abc"), "abc");
  assert.equal(readBearerToken("Bearer\tabc"), "abc");
  assert.equal(readBearerToken("Bearer" + " ".repeat(200_000) + "token"), "token");
});

test("rejects missing or invalid authorization headers", () => {
  for (const header of [undefined, "", "Bearer", "Bearer   ", "Basic abc", "Bearerabc"]) {
    assert.throws(() => readBearerToken(header), /Bearer access token is required/);
  }
});
