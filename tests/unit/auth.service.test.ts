import assert from "node:assert/strict";
import test from "node:test";

import { hashPassword } from "../../src/modules/auth/auth.crypto.js";
import { AuthService } from "../../src/modules/auth/auth.service.js";
import type {
  AuthAccountRecord,
  AuthRepositoryPort,
  AuthSessionRecord,
  AuthUser,
} from "../../src/modules/auth/auth.types.js";

class FakeAuthRepository implements AuthRepositoryPort {
  account: AuthAccountRecord;
  readonly user: AuthUser;
  private session: AuthSessionRecord | null = null;

  constructor(account: AuthAccountRecord, user: AuthUser) {
    this.account = account;
    this.user = user;
  }

  async findAccountByIdentifier(): Promise<AuthAccountRecord | null> {
    return this.account;
  }

  async findAccountByUserId(): Promise<AuthAccountRecord | null> {
    return this.account;
  }

  async getAdminContext(): Promise<AuthUser | null> {
    return this.user;
  }

  async setupPassword(_userId: string, passwordHash: string): Promise<void> {
    this.account = { ...this.account, passwordHash, passwordStatus: "ACTIVE" };
  }

  async changePassword(_userId: string, passwordHash: string): Promise<void> {
    this.account = { ...this.account, passwordHash };
  }

  async createSession(
    userId: string,
    refreshTokenHash: string,
    expiresAt: Date,
  ): Promise<AuthSessionRecord> {
    this.session = {
      id: "00000000-0000-0000-0000-000000000002",
      userId,
      refreshTokenHash,
      expiresAt,
      revokedAt: null,
    };
    return this.session;
  }

  async findSessionByRefreshTokenHash(refreshTokenHash: string): Promise<AuthSessionRecord | null> {
    return this.session?.refreshTokenHash === refreshTokenHash ? this.session : null;
  }

  async rotateRefreshToken(
    _sessionId: string,
    currentRefreshTokenHash: string,
    nextRefreshTokenHash: string,
    nextExpiresAt: Date,
  ): Promise<boolean> {
    if (!this.session || this.session.refreshTokenHash !== currentRefreshTokenHash) return false;
    this.session = { ...this.session, refreshTokenHash: nextRefreshTokenHash, expiresAt: nextExpiresAt };
    return true;
  }

  async isSessionActive(sessionId: string, userId: string): Promise<boolean> {
    return this.session?.id === sessionId && this.session.userId === userId && !this.session.revokedAt;
  }

  async revokeSession(): Promise<void> {
    if (this.session) this.session = { ...this.session, revokedAt: new Date() };
  }
}

const user: AuthUser = {
  id: "00000000-0000-0000-0000-000000000001",
  email: "admin@example.com",
  role: "admin",
  profile: { id: "00000000-0000-0000-0000-000000000003", name: "Administrador" },
  permissions: [{ scope: "control", level: "EDIT" }],
  canAccessAdminPanel: true,
};

const config = {
  enabled: true,
  jwtSecret: "0123456789abcdef0123456789abcdef",
  jwtExpiresIn: "15m",
  refreshExpiresInDays: 30,
  secureCookies: false,
};

test("pending administrator can complete first access and receive an authenticated context", async () => {
  const repository = new FakeAuthRepository(
    {
      userId: user.id,
      loginIdentifier: "admin",
      passwordStatus: "PENDING",
      name: "Admin",
      email: "admin@example.com",
      passwordHash: null,
    },
    user,
  );
  const service = new AuthService(repository, config);

  const session = await service.setupPassword("admin", "new-password-123");
  assert.equal(repository.account.passwordStatus, "ACTIVE");
  assert.equal(session.payload.user.id, user.id);

  const principal = await service.authenticateAccessToken(session.payload.accessToken);
  assert.equal(principal.user.canAccessAdminPanel, true);
});

test("active login rejects an invalid password and refresh rotates the token", async () => {
  const passwordHash = await hashPassword("valid-password");
  const repository = new FakeAuthRepository(
    {
      userId: user.id,
      loginIdentifier: "admin",
      passwordStatus: "ACTIVE",
      name: "Admin",
      email: "admin@example.com",
      passwordHash,
    },
    user,
  );
  const service = new AuthService(repository, config);

  await assert.rejects(() => service.createSession("admin", "wrong-password"));
  const session = await service.createSession("admin", "valid-password");
  const refreshed = await service.refreshSession(session.refreshToken);
  assert.notEqual(refreshed.refreshToken, session.refreshToken);
  await assert.rejects(() => service.refreshSession(session.refreshToken));
});
