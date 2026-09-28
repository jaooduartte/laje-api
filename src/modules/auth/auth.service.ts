import { ApiError } from "../../common/errors/api-error.js";
import {
  createAccessToken,
  createRefreshToken,
  hashPassword,
  hashRefreshToken,
  parseDurationSeconds,
  verifyAccessToken,
  verifyPassword,
} from "./auth.crypto.js";
import type {
  AuthPrincipal,
  AuthRepositoryPort,
  AuthSessionResult,
  AuthUser,
  LoginState,
} from "./auth.types.js";

export interface AuthServiceConfig {
  enabled: boolean;
  jwtSecret: string | undefined;
  jwtExpiresIn: string | undefined;
  refreshExpiresInDays: number;
  secureCookies: boolean;
}

export class AuthService {
  private readonly accessTokenExpiresInSeconds: number;

  constructor(
    private readonly repository: AuthRepositoryPort,
    private readonly config: AuthServiceConfig,
  ) {
    this.accessTokenExpiresInSeconds = config.jwtExpiresIn
      ? parseDurationSeconds(config.jwtExpiresIn)
      : 3600;
  }

  async resolveLoginState(identifier: string): Promise<LoginState> {
    this.ensureEnabled();
    const account = await this.repository.findAccountByIdentifier(identifier.trim().toLowerCase());
    if (!account) {
      throw new ApiError(404, "ADMIN_USER_NOT_FOUND", "Administrative user was not found.");
    }
    return {
      loginIdentifier: account.loginIdentifier,
      passwordStatus: account.passwordStatus,
    };
  }

  async createSession(identifier: string, password: string): Promise<AuthSessionResult> {
    this.ensureEnabled();
    const account = await this.repository.findAccountByIdentifier(identifier.trim().toLowerCase());
    if (!account || account.passwordStatus !== "ACTIVE" || !account.passwordHash) {
      throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid administrative credentials.");
    }
    if (!(await verifyPassword(password, account.passwordHash))) {
      throw new ApiError(401, "INVALID_CREDENTIALS", "Invalid administrative credentials.");
    }

    const user = await this.requireAccessibleContext(account.userId);
    return this.createPersistedSession(user);
  }

  async setupPassword(identifier: string, newPassword: string): Promise<AuthSessionResult> {
    this.ensureEnabled();
    this.validateNewPassword(newPassword);
    const account = await this.repository.findAccountByIdentifier(identifier.trim().toLowerCase());
    if (!account || account.passwordStatus !== "PENDING") {
      throw new ApiError(409, "PASSWORD_SETUP_NOT_AVAILABLE", "Password setup is not available.");
    }

    await this.repository.setupPassword(account.userId, await hashPassword(newPassword));
    const user = await this.requireAccessibleContext(account.userId);
    return this.createPersistedSession(user);
  }

  async changePassword(
    principal: AuthPrincipal,
    currentPassword: string,
    newPassword: string,
  ): Promise<void> {
    this.ensureEnabled();
    this.validateNewPassword(newPassword);
    const account = await this.repository.findAccountByUserId(principal.userId);
    if (!account?.passwordHash || !(await verifyPassword(currentPassword, account.passwordHash))) {
      throw new ApiError(401, "INVALID_CURRENT_PASSWORD", "Current password is invalid.");
    }
    await this.repository.changePassword(
      principal.userId,
      await hashPassword(newPassword),
      principal.sessionId,
    );
  }

  async refreshSession(refreshToken: string): Promise<AuthSessionResult> {
    this.ensureEnabled();
    if (!refreshToken) {
      throw new ApiError(401, "REFRESH_TOKEN_REQUIRED", "Refresh session is required.");
    }

    const currentHash = hashRefreshToken(refreshToken);
    const session = await this.repository.findSessionByRefreshTokenHash(currentHash);
    if (!session) {
      throw new ApiError(401, "INVALID_REFRESH_TOKEN", "Refresh session is invalid or expired.");
    }

    const user = await this.requireAccessibleContext(session.userId);
    const nextRefresh = createRefreshToken();
    const nextRefreshExpiresAt = this.refreshExpiresAt();
    const rotated = await this.repository.rotateRefreshToken(
      session.id,
      currentHash,
      nextRefresh.hash,
      nextRefreshExpiresAt,
    );
    if (!rotated) {
      throw new ApiError(401, "INVALID_REFRESH_TOKEN", "Refresh session is invalid or expired.");
    }

    return this.issueSessionPayload(user, session.id, nextRefresh.token, nextRefreshExpiresAt);
  }

  async authenticateAccessToken(accessToken: string): Promise<AuthPrincipal> {
    this.ensureEnabled();
    const claims = verifyAccessToken(accessToken, this.jwtSecret());
    if (!claims) {
      throw new ApiError(401, "INVALID_ACCESS_TOKEN", "Access token is invalid or expired.");
    }
    if (!(await this.repository.isSessionActive(claims.sessionId, claims.userId))) {
      throw new ApiError(401, "SESSION_REVOKED", "Administrative session is no longer active.");
    }
    const user = await this.requireAccessibleContext(claims.userId);
    return { userId: claims.userId, sessionId: claims.sessionId, user };
  }

  async revokeSession(principal: AuthPrincipal): Promise<void> {
    await this.repository.revokeSession(principal.sessionId, principal.userId);
  }

  getRefreshCookieConfig(): { maxAgeMs: number; secure: boolean } {
    return {
      maxAgeMs: this.config.refreshExpiresInDays * 86_400_000,
      secure: this.config.secureCookies,
    };
  }

  private async createPersistedSession(user: AuthUser): Promise<AuthSessionResult> {
    const refresh = createRefreshToken();
    const refreshExpiresAt = this.refreshExpiresAt();
    const session = await this.repository.createSession(user.id, refresh.hash, refreshExpiresAt);
    return this.issueSessionPayload(user, session.id, refresh.token, refreshExpiresAt);
  }

  private issueSessionPayload(
    user: AuthUser,
    sessionId: string,
    refreshToken: string,
    refreshExpiresAt: Date,
  ): AuthSessionResult {
    const access = createAccessToken({
      userId: user.id,
      sessionId,
      secret: this.jwtSecret(),
      expiresInSeconds: this.accessTokenExpiresInSeconds,
    });
    return {
      payload: {
        accessToken: access.token,
        tokenType: "Bearer",
        expiresAt: access.expiresAt.toISOString(),
        user,
      },
      refreshToken,
      refreshExpiresAt,
    };
  }

  private refreshExpiresAt(): Date {
    return new Date(Date.now() + this.config.refreshExpiresInDays * 86_400_000);
  }

  private async requireAccessibleContext(userId: string): Promise<AuthUser> {
    const user = await this.repository.getAdminContext(userId);
    if (!user || !user.canAccessAdminPanel) {
      throw new ApiError(403, "ADMIN_ACCESS_DENIED", "Administrative access is not allowed.");
    }
    return user;
  }

  private validateNewPassword(password: string): void {
    if (password.length < 8 || password.length > 128) {
      throw new ApiError(422, "INVALID_PASSWORD", "Password must contain between 8 and 128 characters.");
    }
  }

  private ensureEnabled(): void {
    if (!this.config.enabled) {
      throw new ApiError(503, "AUTH_DISABLED", "Dedicated authentication is not enabled in this environment.");
    }
  }

  private jwtSecret(): string {
    const secret = this.config.jwtSecret;
    if (!secret) {
      throw new ApiError(503, "AUTH_CONFIGURATION_ERROR", "Authentication is not configured.");
    }
    return secret;
  }
}
