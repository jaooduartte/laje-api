import assert from "node:assert/strict";
import test from "node:test";

import { AuthRepository } from "../../src/modules/auth/auth.repository.js";
import type { DatabaseConnection } from "../../src/database/types.js";

const USER = "b37e22a1-8181-43b2-98a1-29db7e864f0a";
const SESSION = "b37e22a1-8181-43b2-98a1-29db7e864f0b";
const PROFILE = "b37e22a1-8181-43b2-98a1-29db7e864f0c";

test("LAJE-38 auth repository maps identity, permissions, sessions and audit writes", async () => {
  const executed: { sql: string; args?: readonly unknown[] }[] = [];
  const account = {
    user_id: USER, login_identifier: "operator", password_status: "ACTIVE",
    name: "Operador", email: "operator@example.invalid", password_hash: "sample-hash",
  };
  const session = {
    id: SESSION, user_id: USER, refresh_token_hash: "a".repeat(64),
    expires_at: "2027-01-01T00:00:00Z", revoked_at: null,
  };
  const query = async (sql: string, args?: readonly unknown[]) => {
    executed.push({ sql, args });
    if (sql.includes("SELECT") && sql.includes("FROM public.admin_user_profiles AS aup")) {
      if (sql.includes("JOIN public.admin_profiles AS ap")) {
        return { rows: [{
          user_id: USER, name: "Operador", login_identifier: "operator",
          email: account.email, profile_id: PROFILE, profile_name: "Mesa",
          role: "mesa",
        }], count: 1 };
      }
      return { rows: [account], count: 1 };
    }
    if (sql.includes("FROM public.admin_profile_permissions")) {
      return { rows: [{ scope: "control", level: "EDIT" }, { scope: "matches", level: "VIEW" }], count: 2 };
    }
    if (sql.includes("admin_auth_sessions")) {
      if (sql.includes("RETURNING id::text") || sql.includes("SELECT id::text")) {
        return { rows: [session], count: 1 };
      }
      return { rows: [], count: 1 };
    }
    return { rows: [], count: 1 };
  };
  const db = { query, transaction: async <T>(work: (tx: { query: typeof query }) => Promise<T>) =>
    work({ query }) } as unknown as DatabaseConnection;
  const repo = new AuthRepository(db);

  const first = await repo.findAccountByIdentifier("operator");
  assert.equal(first?.userId, USER);
  assert.equal(first?.passwordStatus, "ACTIVE");
  assert.equal(first?.email, "operator@example.invalid");

  const second = await repo.findAccountByUserId(USER);
  assert.equal(second?.loginIdentifier, "operator");

  const context = await repo.getAdminContext(USER);
  assert.equal(context?.role, "mesa");
  assert.equal(context?.canAccessAdminPanel, true);
  assert.deepEqual(context?.permissions, [
    { scope: "control", level: "EDIT" },
    { scope: "matches", level: "VIEW" },
  ]);

  await repo.setupPassword(USER, "new-hash");
  await repo.changePassword(USER, "next-hash", SESSION);
  assert.ok(executed.some(({ sql }) => sql.includes("ON CONFLICT (user_id) DO UPDATE")));
  assert.ok(executed.some(({ sql }) => sql.includes("id <> $2::uuid")));

  const created = await repo.createSession(USER, session.refresh_token_hash, new Date(session.expires_at));
  assert.equal(created.id, SESSION);
  assert.equal(created.revokedAt, null);
  const fetched = await repo.findSessionByRefreshTokenHash(session.refresh_token_hash);
  assert.equal(fetched?.userId, USER);
  assert.equal(await repo.rotateRefreshToken(SESSION, "old", "new", new Date(session.expires_at)), true);
  assert.equal(await repo.isSessionActive(SESSION, USER), true);
  await repo.revokeSession(SESSION, USER);
  assert.ok(executed.some(({ sql }) => sql.includes("INSERT INTO public.admin_action_logs")));
  assert.ok(executed.some(({ sql }) => sql.includes("SET revoked_at = COALESCE")));
});
