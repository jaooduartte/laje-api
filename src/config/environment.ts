import "dotenv/config";

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

function required(name: string): string {
  const value = raw(name);
  if (!value) {
    issues.push(`${name} is required.`);
    return "";
  }
  return value;
}

function optional(name: string): string | undefined {
  return raw(name);
}

function enumValue<T extends readonly string[]>(name: string, values: T): T[number] {
  const value = required(name);
  if (value && !(values as readonly string[]).includes(value)) {
    issues.push(`${name} must be one of: ${values.join(", ")}.`);
  }
  return value as T[number];
}

function integer(name: string, min: number, max: number): number {
  const value = required(name);
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

function url(name: string): string {
  const value = required(name);
  if (value) {
    try {
      new URL(value);
    } catch {
      issues.push(`${name} must be a valid URL.`);
    }
  }
  return value;
}

function csvUrls(name: string): string[] {
  const value = required(name);
  const entries = value
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);

  if (entries.length === 0) {
    issues.push(`${name} must contain at least one origin.`);
  }

  for (const entry of entries) {
    try {
      new URL(entry);
    } catch {
      issues.push(`${name} contains an invalid origin: ${entry}.`);
    }
  }

  return entries;
}

const nodeEnv = enumValue("NODE_ENV", ["development", "test", "production"] as const);
const authEnabled = booleanValue("AUTH_ENABLED", false);
const awsEnabled = booleanValue("AWS_ENABLED", false);
const mailEnabled = booleanValue("MAIL_ENABLED", false);

const authJwtSecret = optional("AUTH_JWT_SECRET");
const authJwtExpiresIn = optional("AUTH_JWT_EXPIRES_IN");
if (authEnabled) {
  if (!authJwtSecret || authJwtSecret.length < 32) {
    issues.push("AUTH_JWT_SECRET is required when AUTH_ENABLED=true and must contain at least 32 characters.");
  }
  if (!authJwtExpiresIn) {
    issues.push("AUTH_JWT_EXPIRES_IN is required when AUTH_ENABLED=true.");
  }
}

const awsRegion = optional("AWS_REGION");
if (awsEnabled && !awsRegion) {
  issues.push("AWS_REGION is required when AWS_ENABLED=true.");
}

const mailHost = optional("MAIL_HOST");
const mailUser = optional("MAIL_USER");
const mailPassword = optional("MAIL_PASSWORD");
const mailFrom = optional("MAIL_FROM");
if (mailEnabled) {
  if (!mailHost) issues.push("MAIL_HOST is required when MAIL_ENABLED=true.");
  if (!mailUser) issues.push("MAIL_USER is required when MAIL_ENABLED=true.");
  if (!mailPassword) issues.push("MAIL_PASSWORD is required when MAIL_ENABLED=true.");
  if (!mailFrom) issues.push("MAIL_FROM is required when MAIL_ENABLED=true.");
}

export const environment = Object.freeze({
  nodeEnv,
  port: integer("PORT", 1, 65535),
  databaseUrl: url("DATABASE_URL"),
  corsOrigins: csvUrls("CORS_ORIGINS"),
  auth: Object.freeze({
    enabled: authEnabled,
    jwtSecret: authJwtSecret,
    jwtExpiresIn: authJwtExpiresIn,
  }),
  aws: Object.freeze({
    enabled: awsEnabled,
    region: awsRegion,
    secretsPrefix: optional("AWS_SECRETS_PREFIX"),
  }),
  mail: Object.freeze({
    enabled: mailEnabled,
    host: mailHost,
    port: optionalInteger("MAIL_PORT", 587, 1, 65535),
    secure: booleanValue("MAIL_SECURE", false),
    user: mailUser,
    password: mailPassword,
    from: mailFrom,
  }),
});

if (issues.length > 0) {
  throw new ConfigurationError(issues);
}
