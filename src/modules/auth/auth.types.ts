export type AdminRole = "admin" | "eventos" | "mesa" | null;
export type AdminPermissionLevel = "NONE" | "VIEW" | "EDIT";
export type AdminPasswordStatus = "PENDING" | "ACTIVE";

export interface AdminPermission {
  scope: string;
  level: AdminPermissionLevel;
}

export interface AuthUser {
  id: string;
  email: string | null;
  role: AdminRole;
  profile: { id: string; name: string } | null;
  permissions: AdminPermission[];
  canAccessAdminPanel: boolean;
}

export interface AuthAccountRecord {
  userId: string;
  loginIdentifier: string;
  passwordStatus: AdminPasswordStatus;
  name: string;
  email: string | null;
  passwordHash: string | null;
}

export interface AuthSessionRecord {
  id: string;
  userId: string;
  refreshTokenHash: string;
  expiresAt: Date;
  revokedAt: Date | null;
}

export interface AuthPrincipal {
  userId: string;
  sessionId: string;
  user: AuthUser;
}

export interface AuthSessionPayload {
  accessToken: string;
  tokenType: "Bearer";
  expiresAt: string;
  user: AuthUser;
}

export interface AuthSessionResult {
  payload: AuthSessionPayload;
  refreshToken: string;
  refreshExpiresAt: Date;
}

export interface LoginState {
  loginIdentifier: string;
  passwordStatus: AdminPasswordStatus;
}

export interface AuthRepositoryPort {
  findAccountByIdentifier(identifier: string): Promise<AuthAccountRecord | null>;
  findAccountByUserId(userId: string): Promise<AuthAccountRecord | null>;
  getAdminContext(userId: string): Promise<AuthUser | null>;
  setupPassword(userId: string, passwordHash: string): Promise<void>;
  changePassword(userId: string, passwordHash: string, currentSessionId: string): Promise<void>;
  createSession(
    userId: string,
    refreshTokenHash: string,
    expiresAt: Date,
  ): Promise<AuthSessionRecord>;
  findSessionByRefreshTokenHash(refreshTokenHash: string): Promise<AuthSessionRecord | null>;
  rotateRefreshToken(
    sessionId: string,
    currentRefreshTokenHash: string,
    nextRefreshTokenHash: string,
    nextExpiresAt: Date,
  ): Promise<boolean>;
  isSessionActive(sessionId: string, userId: string): Promise<boolean>;
  revokeSession(sessionId: string, userId: string): Promise<void>;
}
