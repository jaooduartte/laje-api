import assert from "node:assert/strict";
import test from "node:test";

import {
  createAccessToken,
  createRefreshToken,
  hashPassword,
  hashRefreshToken,
  parseDurationSeconds,
  verifyAccessToken,
  verifyPassword,
} from "../../src/modules/auth/auth.crypto.js";

const SECRET = "0123456789abcdef0123456789abcdef";

test("password hashes use salted scrypt and verify without exposing the password", async () => {
  const firstHash = await hashPassword("password-123");
  const secondHash = await hashPassword("password-123");

  assert.notEqual(firstHash, secondHash);
  assert.equal(await verifyPassword("password-123", firstHash), true);
  assert.equal(await verifyPassword("wrong-password", firstHash), false);
  assert.equal(firstHash.includes("password-123"), false);
});

test("access token validates issuer, session and expiration", () => {
  const result = createAccessToken({
    userId: "00000000-0000-0000-0000-000000000001",
    sessionId: "00000000-0000-0000-0000-000000000002",
    secret: SECRET,
    expiresInSeconds: 900,
    nowSeconds: 1_000,
  });

  assert.deepEqual(verifyAccessToken(result.token, SECRET, 1_100), {
    userId: "00000000-0000-0000-0000-000000000001",
    sessionId: "00000000-0000-0000-0000-000000000002",
  });
  assert.equal(verifyAccessToken(result.token, SECRET, 1_901), null);
  assert.equal(verifyAccessToken(`${result.token}tampered`, SECRET, 1_100), null);
});

test("refresh tokens are random and persisted only through deterministic hashes", () => {
  const first = createRefreshToken();
  const second = createRefreshToken();

  assert.notEqual(first.token, second.token);
  assert.equal(first.hash, hashRefreshToken(first.token));
  assert.equal(first.hash.length, 64);
});

test("JWT duration parser enforces short-lived access tokens", () => {
  assert.equal(parseDurationSeconds("15m"), 900);
  assert.equal(parseDurationSeconds("1h"), 3600);
  assert.throws(() => parseDurationSeconds("30d"));
  assert.throws(() => parseDurationSeconds("abc"));
});
