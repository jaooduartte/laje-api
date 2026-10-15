import assert from "node:assert/strict";
import test from "node:test";

import {
  createAccessToken,
  createRefreshToken,
  encryptRefreshCookieToken,
  decryptRefreshCookieToken,
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

test("refresh token browser cookies use AES-256-GCM authenticated encryption", () => {
  const token = createRefreshToken().token;
  const encrypted = encryptRefreshCookieToken(token, SECRET);
  const encryptedAgain = encryptRefreshCookieToken(token, SECRET);
  assert.match(encrypted, /^v1\./);
  assert.notEqual(encrypted, encryptedAgain, "Each cookie must use a fresh nonce");
  assert.equal(encrypted.includes(token), false, "Raw token must not appear in the cookie");
  assert.equal(decryptRefreshCookieToken(encrypted, SECRET), token);
  assert.equal(decryptRefreshCookieToken(encrypted, "another-secret"), null);
  const parts = encrypted.split(".");
  parts[3] = parts[3]?.slice(0, -1) + (parts[3]?.at(-1) === "A" ? "B" : "A");
  assert.equal(decryptRefreshCookieToken(parts.join("."), SECRET), null);
});

test("existing opaque refresh cookies remain accepted during migration", () => {
  const legacyToken = createRefreshToken().token;
  assert.equal(decryptRefreshCookieToken(legacyToken, SECRET), legacyToken);
  assert.equal(decryptRefreshCookieToken("bad-token", SECRET), null);
  assert.equal(decryptRefreshCookieToken("v1.bad.bad.bad", SECRET), null);
  assert.equal(decryptRefreshCookieToken("", SECRET), null);
});
