import "dotenv/config";

import { resolveDatabaseUrl } from "./database-url.js";
import { createRedactedConfig } from "./redacted-config.js";

export type NodeEnvironment = "development" | "test" | "production";

type RawValue = string | undefined;

export class ConfigurationError extends Error {
  constructor(issues: string[]) {
    super(`Invalid environment configuration:\n- ${issues.join("\n- ")}`);
    this.name = "ConfigurationError";
  }
}

const issues: string[] = [];

function raw(name: string): RawValue {
  const value = process.env[name]?.trim();
  return value && value.length > 0 ? value : undefined;
}

function required(name: string): string | undefined {
  const value = raw(name);
  if (!value) {
    issues.push(`${name} is required.`);
  }
  return value;
}

function optional(name: string): string | undefined {
  return raw(name);
}

function enumValue<T extends readonly string[]>(name: string, values: T): T[number] | undefined {
  const value = required(name);
  if (!value) return undefined;

  if (!(values as readonly string[]).includes(value)) {
    issues.push(`${name} must be one of: ${values.join(", ")}.`);
  }
  return value as T[number];
}

function integer(name: string, min: number, max: number): number | undefined {
  const value = required(name);
  if (!value) return undefined;

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
    issues.push(`${name} must be an integer between ${min} and ${max}.`);
  }
  return parsed;
}

function optionalInteger(name: string, fallback: number, min: number, max: number): number {
  const value = optional(name);
  if (!value) return fallback;

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < min || parsed > max) {
    issues.push(`${name} must be an integer between ${min} and ${max}.`);
  }
  return parsed;
}

function booleanValue(name: string, fallback: boolean): boolean {
  const value = optional(name);
  if (!value) return fallback;
  if (value !== "true" && value !== "false") {
    issues.push(`${name} must be either true or false.`);
  }
  return value === "true";
}

function csvOrigins(name: string): string[] | undefined {
  const value = required(name);
  if (!value) return undefined;

  const entries = value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);

  if (entries.length === 0) {
    issues.push(`${name} must contain at least one origin.`);
    return [];
  }

  const origins = new Set<string>();

  for (const entry of entries) {
    try {
      const parsed = new URL(entry);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        issues.push(`${name} contains an unsupported origin protocol: ${entry}.`);
        continue;
      }
      origins.add(parsed.origin);
    } catch {
      issues.push(`${name} contains an invalid origin: ${entry}.`);
    }
  }

  return [...origins];
}

const nodeEnv = enumValue("NODE_ENV", ["development", "test", "production"] as const);
const port = integer("PORT", 1, 65535);
const databaseResolution = resolveDatabaseUrl({
  url: optional("DATABASE_URL"),
  host: optional("DATABASE_HOST"),
  port: optional("DATABASE_PORT"),
  database: optional("DATABASE_NAME"),
  user: optional("DATABASE_USER"),
  password: optional("DATABASE_PASSWORD"),
  sslMode: optional("DATABASE_SSLMODE"),
});
issues.push(...databaseResolution.issues);
const databaseUrl = databaseResolution.url;
const databasePoolMax = optionalInteger("DATABASE_POOL_MAX", 10, 1, 50);
const databaseIdleTimeoutSeconds = optionalInteger("DATABASE_IDLE_TIMEOUT_SECONDS", 20, 1, 300);
const databaseConnectTimeoutSeconds = optionalInteger(
  "DATABASE_CONNECT_TIMEOUT_SECONDS",
  10,
  1,
  60,
);
const databaseShutdownTimeoutSeconds = optionalInteger(
  "DATABASE_SHUTDOWN_TIMEOUT_SECONDS",
  5,
  1,
  30,
);
const corsOrigins = csvOrigins("CORS_ORIGINS");

const authEnabled = booleanValue("AUTH_ENABLED", false);
const awsEnabled = booleanValue("AWS_ENABLED", false);
const mailEnabled = booleanValue("MAIL_ENABLED", false);

const authJwtSecret = optional("AUTH_JWT_SECRET");
const authJwtExpiresIn = optional("AUTH_JWT_EXPIRES_IN");
const authRefreshExpiresInDays = optionalInteger("AUTH_REFRESH_EXPIRES_IN_DAYS", 30, 1, 90);
if (authEnabled) {
  if (!authJwtSecret || authJwtSecret.length < 32) {
    issues.push(
      "AUTH_JWT_SECRET is required when AUTH_ENABLED=true and must contain at least 32 characters.",
    );
  }
  if (!authJwtExpiresIn) {
    issues.push("AUTH_JWT_EXPIRES_IN is required when AUTH_ENABLED=true.");
  }
}

const awsRegion = optional("AWS_REGION");
const bracketPreviewQueueUrl = optional("BRACKET_PREVIEW_QUEUE_URL");
const bracketPreviewWorkerEnabled = booleanValue("BRACKET_PREVIEW_WORKER_ENABLED", false);
const bracketPreviewPollWaitSeconds = optionalInteger("BRACKET_PREVIEW_POLL_WAIT_SECONDS", 20, 1, 20);
const bracketPreviewVisibilityTimeoutSeconds = optionalInteger(
  "BRACKET_PREVIEW_VISIBILITY_TIMEOUT_SECONDS",
  180,
  30,
  900,
);
if (awsEnabled && !awsRegion) {
  issues.push("AWS_REGION is required when AWS_ENABLED=true.");
}
if (bracketPreviewWorkerEnabled && !bracketPreviewQueueUrl) {
  issues.push("BRACKET_PREVIEW_QUEUE_URL is required when BRACKET_PREVIEW_WORKER_ENABLED=true.");
}

const mailFrom = optional("MAIL_FROM");
const mailFromName = optional("MAIL_FROM_NAME") ?? "C.O. - Liga das Atléticas de Joinville";
const brevoApiKey = optional("BREVO_API_KEY");
const coEventsEmail = optional("CO_EVENTS_EMAIL");
const coPresidencyEmail = optional("CO_PRESIDENCY_EMAIL");
const appUrl = optional("APP_URL") ?? "https://laje-tcc.vercel.app";
if (mailEnabled) {
  if (!brevoApiKey) issues.push("BREVO_API_KEY is required when MAIL_ENABLED=true.");
  if (!mailFrom) issues.push("MAIL_FROM is required when MAIL_ENABLED=true.");
  if (!coEventsEmail) issues.push("CO_EVENTS_EMAIL is required when MAIL_ENABLED=true.");
  if (!coPresidencyEmail) issues.push("CO_PRESIDENCY_EMAIL is required when MAIL_ENABLED=true.");
}

if (
  issues.length > 0 ||
  !nodeEnv ||
  port === undefined ||
  !databaseUrl ||
  corsOrigins === undefined
) {
  throw new ConfigurationError(issues);
}

const auth = createRedactedConfig(
  {
    enabled: authEnabled,
    jwtSecret: authJwtSecret,
    jwtExpiresIn: authJwtExpiresIn,
    refreshExpiresInDays: authRefreshExpiresInDays,
  },
  ["jwtSecret"] as const,
);

const mail = createRedactedConfig(
  {
    enabled: mailEnabled,
    provider: "brevo" as const,
    brevoApiKey,
    from: mailFrom,
    fromName: mailFromName,
    coEventsEmail,
    coPresidencyEmail,
    appUrl,
  },
  ["brevoApiKey"] as const,
);

export const environment = createRedactedConfig(
  {
    nodeEnv,
    port,
    databaseUrl,
    databasePoolMax,
    databaseIdleTimeoutSeconds,
    databaseConnectTimeoutSeconds,
    databaseShutdownTimeoutSeconds,
    corsOrigins,
    auth,
    aws: Object.freeze({
      enabled: awsEnabled,
      region: awsRegion,
      secretsPrefix: optional("AWS_SECRETS_PREFIX"),
      bracketPreviewQueueUrl,
      bracketPreviewWorkerEnabled,
      bracketPreviewPollWaitSeconds,
      bracketPreviewVisibilityTimeoutSeconds,
    }),
    mail,
  },
  ["databaseUrl"] as const,
);
