import { ApiError } from "../../common/errors/api-error.js";

function objectBody(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", "Request body must be a JSON object.");
  }
  return value as Record<string, unknown>;
}

function requiredString(body: Record<string, unknown>, field: string): string {
  const value = body[field];
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new ApiError(422, "VALIDATION_ERROR", "One or more fields are invalid.", [
      { field, code: "REQUIRED", message: `${field} is required.` },
    ]);
  }
  return value;
}

export function parseLoginIdentifierBody(value: unknown): { loginIdentifier: string } {
  const body = objectBody(value);
  return { loginIdentifier: requiredString(body, "loginIdentifier").trim().toLowerCase() };
}

export function parseLoginBody(value: unknown): { loginIdentifier: string; password: string } {
  const body = objectBody(value);
  return {
    loginIdentifier: requiredString(body, "loginIdentifier").trim().toLowerCase(),
    password: requiredString(body, "password"),
  };
}

export function parsePasswordSetupBody(value: unknown): {
  loginIdentifier: string;
  newPassword: string;
} {
  const body = objectBody(value);
  return {
    loginIdentifier: requiredString(body, "loginIdentifier").trim().toLowerCase(),
    newPassword: requiredString(body, "newPassword"),
  };
}

export function parsePasswordChangeBody(value: unknown): {
  currentPassword: string;
  newPassword: string;
} {
  const body = objectBody(value);
  return {
    currentPassword: requiredString(body, "currentPassword"),
    newPassword: requiredString(body, "newPassword"),
  };
}

export function readBearerToken(authorizationHeader: string | undefined): string {
  const match = /^Bearer\s+(.+)$/i.exec(authorizationHeader ?? "");
  if (!match?.[1]) {
    throw new ApiError(401, "ACCESS_TOKEN_REQUIRED", "Bearer access token is required.");
  }
  return match[1].trim();
}

export function readCookie(cookieHeader: string | undefined, name: string): string {
  const cookies = (cookieHeader ?? "").split(";");
  for (const cookie of cookies) {
    const separator = cookie.indexOf("=");
    if (separator < 0) continue;
    const key = cookie.slice(0, separator).trim();
    if (key === name) return decodeURIComponent(cookie.slice(separator + 1).trim());
  }
  return "";
}
