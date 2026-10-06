export interface DatabaseUrlInput {
  url?: string;
  host?: string;
  port?: string;
  database?: string;
  user?: string;
  password?: string;
  sslMode?: string;
}

export interface DatabaseUrlResolution {
  url?: string;
  issues: string[];
}

const sslModes = new Set(["disable", "allow", "prefer", "require", "verify-ca", "verify-full"]);

function normalized(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? trimmed : undefined;
}

export function resolveDatabaseUrl(input: DatabaseUrlInput): DatabaseUrlResolution {
  const directUrl = normalized(input.url);
  if (directUrl) {
    try {
      const parsed = new URL(directUrl);
      if (parsed.protocol !== "postgres:" && parsed.protocol !== "postgresql:") {
        return {
          issues: ["DATABASE_URL must use the postgres:// or postgresql:// protocol."],
        };
      }
      return { url: directUrl, issues: [] };
    } catch {
      return { issues: ["DATABASE_URL must be a valid PostgreSQL URL."] };
    }
  }

  const values = {
    host: normalized(input.host),
    database: normalized(input.database),
    user: normalized(input.user),
    password: normalized(input.password),
  };

  const missing = Object.entries(values)
    .filter(([, value]) => !value)
    .map(([key]) => key);

  if (missing.length > 0) {
    return {
      issues: [
        "DATABASE_URL is required unless DATABASE_HOST, DATABASE_NAME, DATABASE_USER and DATABASE_PASSWORD are all configured.",
      ],
    };
  }

  const portValue = normalized(input.port) ?? "5432";
  const port = Number(portValue);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return { issues: ["DATABASE_PORT must be an integer between 1 and 65535."] };
  }

  const sslMode = normalized(input.sslMode) ?? "require";
  if (!sslModes.has(sslMode)) {
    return {
      issues: [
        "DATABASE_SSLMODE must be one of: disable, allow, prefer, require, verify-ca, verify-full.",
      ],
    };
  }

  const host = values.host as string;
  if (/\s|\//.test(host)) {
    return { issues: ["DATABASE_HOST must be a hostname or IP address without a path."] };
  }

  const database = encodeURIComponent(values.database as string);
  const user = encodeURIComponent(values.user as string);
  const password = encodeURIComponent(values.password as string);

  return {
    url: `postgresql://${user}:${password}@${host}:${port}/${database}?sslmode=${sslMode}`,
    issues: [],
  };
}
