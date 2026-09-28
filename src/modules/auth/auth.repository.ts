import type { DatabaseConnection, DatabaseQueryExecutor } from "../../database/types.js";
import type {
  AdminPermission,
  AdminPermissionLevel,
  AdminRole,
  AuthAccountRecord,
  AuthRepositoryPort,
  AuthSessionRecord,
  AuthUser,
} from "./auth.types.js";

interface AccountRow extends Record<string, unknown> {
  user_id: string;
  login_identifier: string;
  password_status: string;
  name: string;
  email: string | null;
  password_hash: string | null;
}

interface ContextRow extends Record<string, unknown> {
  user_id: string;
  name: string;
  login_identifier: string;
  email: string | null;
  profile_id: string;
  profile_name: string;
  role: string | null;
}

interface PermissionRow extends Record<string, unknown> {
  scope: string;
  level: string;
}

interface SessionRow extends Record<string, unknown> {
  id: string;
  user_id: string;
  refresh_token_hash: string;
  expires_at: Date | string;
  revoked_at: Date | string | null;
}

function mapAccount(row: AccountRow): AuthAccountRecord {
  return {
    userId: row.user_id,
    loginIdentifier: row.login_identifier,
    passwordStatus: row.password_status === "ACTIVE" ? "ACTIVE" : "PENDING",
    name: row.name,
    email: row.email,
    passwordHash: row.password_hash,
  };
}

function mapSession(row: SessionRow): AuthSessionRecord {
  return {
    id: row.id,
    userId: row.user_id,
    refreshTokenHash: row.refresh_token_hash,
    expiresAt: new Date(row.expires_at),
    revokedAt: row.revoked_at == null ? null : new Date(row.revoked_at),
  };
}

export class AuthRepository implements AuthRepositoryPort {
  constructor(private readonly database: DatabaseConnection) {}

  async findAccountByIdentifier(identifier: string): Promise<AuthAccountRecord | null> {
    const result = await this.database.query<AccountRow>(
      `SELECT
         aup.user_id::text AS user_id,
         aup.login_identifier,
         aup.password_status::text AS password_status,
         aup.name,
         aaa.email,
         aaa.password_hash
       FROM public.admin_user_profiles AS aup
       LEFT JOIN public.admin_auth_accounts AS aaa ON aaa.user_id = aup.user_id
       WHERE lower(aup.login_identifier) = lower($1)
          OR lower(aaa.email) = lower($1)
       LIMIT 1`,
      [identifier],
    );
    const row = result.rows[0];
    return row ? mapAccount(row) : null;
  }

  async findAccountByUserId(userId: string): Promise<AuthAccountRecord | null> {
    const result = await this.database.query<AccountRow>(
      `SELECT
         aup.user_id::text AS user_id,
         aup.login_identifier,
         aup.password_status::text AS password_status,
         aup.name,
         aaa.email,
         aaa.password_hash
       FROM public.admin_user_profiles AS aup
       LEFT JOIN public.admin_auth_accounts AS aaa ON aaa.user_id = aup.user_id
       WHERE aup.user_id = $1::uuid
       LIMIT 1`,
      [userId],
    );
    const row = result.rows[0];
    return row ? mapAccount(row) : null;
  }

  async getAdminContext(userId: string): Promise<AuthUser | null> {
    const contextResult = await this.database.query<ContextRow>(
      `SELECT
         aup.user_id::text AS user_id,
         aup.name,
         aup.login_identifier,
         aaa.email,
         ap.id::text AS profile_id,
         ap.name AS profile_name,
         ap.system_role::text AS role
       FROM public.admin_user_profiles AS aup
       JOIN public.admin_profiles AS ap ON ap.id = aup.profile_id
       LEFT JOIN public.admin_auth_accounts AS aaa ON aaa.user_id = aup.user_id
       WHERE aup.user_id = $1::uuid
       LIMIT 1`,
      [userId],
    );
    const context = contextResult.rows[0];
    if (!context) return null;

    const permissionResult = await this.database.query<PermissionRow>(
      `SELECT admin_tab::text AS scope, access_level::text AS level
       FROM public.admin_profile_permissions
       WHERE profile_id = $1::uuid
       ORDER BY admin_tab::text`,
      [context.profile_id],
    );

    const permissions: AdminPermission[] = permissionResult.rows.map((row) => ({
      scope: row.scope,
      level: row.level as AdminPermissionLevel,
    }));
    const role =
      context.role === "admin" || context.role === "eventos" || context.role === "mesa"
        ? (context.role as AdminRole)
        : null;

    return {
      id: context.user_id,
      email: context.email,
      role,
      profile: { id: context.profile_id, name: context.profile_name },
      permissions,
      canAccessAdminPanel: permissions.some((permission) => permission.level !== "NONE"),
    };
  }

  async setupPassword(userId: string, passwordHash: string): Promise<void> {
    await this.database.transaction(async (executor) => {
      await executor.query(
        `INSERT INTO public.admin_auth_accounts (user_id, password_hash, password_changed_at)
         VALUES ($1::uuid, $2, now())
         ON CONFLICT (user_id) DO UPDATE SET
           password_hash = excluded.password_hash,
           password_changed_at = now(),
           updated_at = now()`,
        [userId, passwordHash],
      );
      await executor.query(
        `UPDATE public.admin_user_profiles
         SET password_status = 'ACTIVE'::public.admin_user_password_status, updated_at = now()
         WHERE user_id = $1::uuid`,
        [userId],
      );
      await this.writeAudit(executor, userId, "PASSWORD_CHANGED", "admin_auth_accounts", userId,
        "Senha administrativa definida na arquitetura dedicada.");
    });
  }

  async changePassword(
    userId: string,
    passwordHash: string,
    currentSessionId: string,
  ): Promise<void> {
    await this.database.transaction(async (executor) => {
      await executor.query(
        `UPDATE public.admin_auth_accounts
         SET password_hash = $2, password_changed_at = now(), updated_at = now()
         WHERE user_id = $1::uuid`,
        [userId, passwordHash],
      );
      await executor.query(
        `UPDATE public.admin_auth_sessions
         SET revoked_at = now()
         WHERE user_id = $1::uuid AND id <> $2::uuid AND revoked_at IS NULL`,
        [userId, currentSessionId],
      );
      await this.writeAudit(executor, userId, "PASSWORD_CHANGED", "admin_auth_accounts", userId,
        "Senha administrativa alterada na arquitetura dedicada.");
    });
  }

  async createSession(
    userId: string,
    refreshTokenHash: string,
    expiresAt: Date,
  ): Promise<AuthSessionRecord> {
    return this.database.transaction(async (executor) => {
      const result = await executor.query<SessionRow>(
        `INSERT INTO public.admin_auth_sessions (user_id, refresh_token_hash, expires_at)
         VALUES ($1::uuid, $2, $3)
         RETURNING id::text, user_id::text, refresh_token_hash, expires_at, revoked_at`,
        [userId, refreshTokenHash, expiresAt],
      );
      const row = result.rows[0];
      if (!row) throw new Error("Failed to persist administrative session.");
      await this.writeAudit(executor, userId, "LOGIN", "admin_auth_sessions", row.id,
        "Login administrativo realizado pela laje-api.");
      return mapSession(row);
    });
  }

  async findSessionByRefreshTokenHash(refreshTokenHash: string): Promise<AuthSessionRecord | null> {
    const result = await this.database.query<SessionRow>(
      `SELECT id::text, user_id::text, refresh_token_hash, expires_at, revoked_at
       FROM public.admin_auth_sessions
       WHERE refresh_token_hash = $1 AND revoked_at IS NULL AND expires_at > now()
       LIMIT 1`,
      [refreshTokenHash],
    );
    const row = result.rows[0];
    return row ? mapSession(row) : null;
  }

  async rotateRefreshToken(
    sessionId: string,
    currentRefreshTokenHash: string,
    nextRefreshTokenHash: string,
    nextExpiresAt: Date,
  ): Promise<boolean> {
    const result = await this.database.query(
      `UPDATE public.admin_auth_sessions
       SET refresh_token_hash = $3, expires_at = $4, last_used_at = now()
       WHERE id = $1::uuid
         AND refresh_token_hash = $2
         AND revoked_at IS NULL
         AND expires_at > now()`,
      [sessionId, currentRefreshTokenHash, nextRefreshTokenHash, nextExpiresAt],
    );
    return result.count === 1;
  }

  async isSessionActive(sessionId: string, userId: string): Promise<boolean> {
    const result = await this.database.query(
      `SELECT 1
       FROM public.admin_auth_sessions
       WHERE id = $1::uuid AND user_id = $2::uuid AND revoked_at IS NULL AND expires_at > now()
       LIMIT 1`,
      [sessionId, userId],
    );
    return result.count === 1;
  }

  async revokeSession(sessionId: string, userId: string): Promise<void> {
    await this.database.query(
      `UPDATE public.admin_auth_sessions
       SET revoked_at = COALESCE(revoked_at, now()), last_used_at = now()
       WHERE id = $1::uuid AND user_id = $2::uuid`,
      [sessionId, userId],
    );
  }

  private async writeAudit(
    executor: DatabaseQueryExecutor,
    userId: string,
    actionType: "LOGIN" | "PASSWORD_CHANGED",
    resourceTable: string,
    recordId: string,
    description: string,
  ): Promise<void> {
    await executor.query(
      `INSERT INTO public.admin_action_logs (
         actor_user_id, actor_email, actor_name, actor_role, action_type,
         resource_table, record_id, description, metadata
       )
       SELECT
         aup.user_id,
         aaa.email,
         aup.name,
         ap.system_role,
         $2::public.admin_action_type,
         $3,
         $4,
         $5,
         jsonb_build_object('source', 'laje-api')
       FROM public.admin_user_profiles AS aup
       JOIN public.admin_profiles AS ap ON ap.id = aup.profile_id
       LEFT JOIN public.admin_auth_accounts AS aaa ON aaa.user_id = aup.user_id
       WHERE aup.user_id = $1::uuid`,
      [userId, actionType, resourceTable, recordId, description],
    );
  }
}
