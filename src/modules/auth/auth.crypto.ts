import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  createHash,
  randomBytes,
  scrypt,
  timingSafeEqual,
} from "node:crypto";

const SCRYPT_KEY_LENGTH = 64;
const SCRYPT_N = 16_384;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const ACCESS_TOKEN_ISSUER = "laje-api";
const ACCESS_TOKEN_AUDIENCE = "laje-admin";

interface AccessTokenClaims {
  iss: string;
  aud: string;
  sub: string;
  sid: string;
  iat: number;
  exp: number;
}

function scryptAsync(password: string, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(
      password,
      salt,
      SCRYPT_KEY_LENGTH,
      { N: SCRYPT_N, r: SCRYPT_R, p: SCRYPT_P, maxmem: 64 * 1024 * 1024 },
      (error, derivedKey) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(derivedKey);
      },
    );
  });
}

export async function hashPassword(password: string): Promise<string> {
  const salt = randomBytes(16);
  const derivedKey = await scryptAsync(password, salt);
  return [
    "scrypt",
    SCRYPT_N,
    SCRYPT_R,
    SCRYPT_P,
    salt.toString("base64url"),
    derivedKey.toString("base64url"),
  ].join("$");
}

export async function verifyPassword(password: string, encodedHash: string): Promise<boolean> {
  const [algorithm, nValue, rValue, pValue, encodedSalt, encodedKey] = encodedHash.split("$");
  if (
    algorithm !== "scrypt" ||
    Number(nValue) !== SCRYPT_N ||
    Number(rValue) !== SCRYPT_R ||
    Number(pValue) !== SCRYPT_P ||
    !encodedSalt ||
    !encodedKey
  ) {
    return false;
  }

  const expected = Buffer.from(encodedKey, "base64url");
  const actual = await scryptAsync(password, Buffer.from(encodedSalt, "base64url"));
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

export function parseDurationSeconds(value: string): number {
  const normalized = value.trim().toLowerCase();
  const match = /^(\d+)(s|m|h|d)$/.exec(normalized);
  if (!match) {
    throw new Error("AUTH_JWT_EXPIRES_IN must use the format <number>s|m|h|d.");
  }

  const amount = Number(match[1]);
  const unit = match[2];
  const multiplier = unit === "s" ? 1 : unit === "m" ? 60 : unit === "h" ? 3600 : 86_400;
  const seconds = amount * multiplier;
  if (!Number.isSafeInteger(seconds) || seconds < 60 || seconds > 86_400) {
    throw new Error("AUTH_JWT_EXPIRES_IN must resolve to between 60 seconds and 24 hours.");
  }
  return seconds;
}

function encodeJson(value: object): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function signToken(input: string, secret: string): string {
  return createHmac("sha256", secret).update(input).digest("base64url");
}

export function createAccessToken(input: {
  userId: string;
  sessionId: string;
  secret: string;
  expiresInSeconds: number;
  nowSeconds?: number;
}): { token: string; expiresAt: Date } {
  const issuedAt = input.nowSeconds ?? Math.floor(Date.now() / 1000);
  const expiresAtSeconds = issuedAt + input.expiresInSeconds;
  const header = encodeJson({ alg: "HS256", typ: "JWT" });
  const payload = encodeJson({
    iss: ACCESS_TOKEN_ISSUER,
    aud: ACCESS_TOKEN_AUDIENCE,
    sub: input.userId,
    sid: input.sessionId,
    iat: issuedAt,
    exp: expiresAtSeconds,
  });
  const unsignedToken = `${header}.${payload}`;
  return {
    token: `${unsignedToken}.${signToken(unsignedToken, input.secret)}`,
    expiresAt: new Date(expiresAtSeconds * 1000),
  };
}

export function verifyAccessToken(
  token: string,
  secret: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): { userId: string; sessionId: string } | null {
  const [header, payload, signature] = token.split(".");
  if (!header || !payload || !signature) return null;

  const expectedSignature = signToken(`${header}.${payload}`, secret);
  const actualBuffer = Buffer.from(signature, "base64url");
  const expectedBuffer = Buffer.from(expectedSignature, "base64url");
  if (
    actualBuffer.length !== expectedBuffer.length ||
    !timingSafeEqual(actualBuffer, expectedBuffer)
  ) {
    return null;
  }

  try {
    const claims = JSON.parse(
      Buffer.from(payload, "base64url").toString("utf8"),
    ) as Partial<AccessTokenClaims>;
    if (
      claims.iss !== ACCESS_TOKEN_ISSUER ||
      claims.aud !== ACCESS_TOKEN_AUDIENCE ||
      typeof claims.sub !== "string" ||
      typeof claims.sid !== "string" ||
      typeof claims.iat !== "number" ||
      typeof claims.exp !== "number" ||
      claims.iat > nowSeconds + 60 ||
      claims.exp <= nowSeconds
    ) {
      return null;
    }
    return { userId: claims.sub, sessionId: claims.sid };
  } catch {
    return null;
  }
}

export function createRefreshToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString("base64url");
  return { token, hash: hashRefreshToken(token) };
}

export function hashRefreshToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

/**
 * Encrypt opaque refresh tokens before writing them to a browser cookie.
 * Domain-separated key derivation means cookie encryption does not reuse the
 * JWT signing key directly. The database continues storing only token hashes.
 */
function refreshCookieKey(secret: string): Buffer {
  return createHmac("sha256", secret).update("laje-refresh-cookie-encryption-v1").digest();
}

export function encryptRefreshCookieToken(token: string, secret: string): string {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", refreshCookieKey(secret), iv);
  const encrypted = Buffer.concat([cipher.update(token, "utf8"), cipher.final()]);
  return [
    "v1",
    iv.toString("base64url"),
    cipher.getAuthTag().toString("base64url"),
    encrypted.toString("base64url"),
  ].join(".");
}

/** Returns null for tampered/unsupported cookies. Pre-migration cookies are accepted. */
export function decryptRefreshCookieToken(cookie: string, secret: string): string | null {
  if (!cookie) return null;
  if (!cookie.startsWith("v1.")) {
    // Backward compatibility only for the 32-byte random tokens previously issued.
    return cookie.length === 43 && /^[A-Za-z0-9_-]+$/.test(cookie) ? cookie : null;
  }
  const segments = cookie.split(".");
  if (segments.length !== 4 || segments[0] !== "v1") return null;
  try {
    const iv = Buffer.from(segments[1] ?? "", "base64url");
    const authTag = Buffer.from(segments[2] ?? "", "base64url");
    const payload = Buffer.from(segments[3] ?? "", "base64url");
    if (iv.length !== 12 || authTag.length !== 16 || payload.length === 0) return null;
    const decipher = createDecipheriv("aes-256-gcm", refreshCookieKey(secret), iv);
    decipher.setAuthTag(authTag);
    const token = Buffer.concat([decipher.update(payload), decipher.final()]).toString("utf8");
    return token.length === 43 && /^[A-Za-z0-9_-]+$/.test(token) ? token : null;
  } catch {
    return null;
  }
}
