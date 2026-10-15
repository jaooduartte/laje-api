import { createHash } from "node:crypto";
import type { RequestHandler } from "express";

import { environment } from "../../config/environment.js";
import { database } from "../../database/index.js";
import type { DatabaseQueryExecutor } from "../../database/types.js";

/**
 * A PostgreSQL-backed, atomic fixed-window limiter. Each actor/scope has one row,
 * so all ECS replicas share the same limits without trusting process-local memory.
 */
export interface SensitiveRateLimitOptions {
  scope: string;
  maxRequests: number;
  windowSeconds: number;
  executor?: DatabaseQueryExecutor;
  enabled?: boolean;
}

export function createSensitiveRouteRateLimit(options: SensitiveRateLimitOptions): RequestHandler {
  const executor = options.executor ?? database;
  const enabled = options.enabled ?? environment.auth.enabled;
  const { scope, maxRequests, windowSeconds } = options;
  if (
    !/^[a-z][a-z0-9-]{1,63}$/.test(scope) ||
    !Number.isSafeInteger(maxRequests) ||
    maxRequests < 1 ||
    !Number.isSafeInteger(windowSeconds) ||
    windowSeconds < 1
  ) {
    throw new Error("Invalid rate limit configuration.");
  }

  return async (request, response, next) => {
    if (!enabled) {
      next();
      return;
    }
    try {
      // Never use an untrusted X-Forwarded-For header directly.
      // Express req.ip observes configured trusted proxy hops only.
      const clientIp = request.ip ?? request.socket.remoteAddress ?? "unknown";
      const keyHash = createHash("sha256")
        .update(scope)
        .update("\0")
        .update(clientIp)
        .digest("hex");
      const result = await executor.query<{ hits: number; window_bucket: number }>(
        `INSERT INTO public.api_rate_limit_windows AS bucket
           (key_hash, window_bucket, hits)
         VALUES ($1, floor(extract(epoch FROM clock_timestamp()) / $2)::bigint, 1)
         ON CONFLICT (key_hash) DO UPDATE SET
           hits = CASE WHEN bucket.window_bucket = EXCLUDED.window_bucket
                       THEN bucket.hits + 1 ELSE 1 END,
           window_bucket = GREATEST(bucket.window_bucket, EXCLUDED.window_bucket)
         RETURNING hits, window_bucket`,
        [keyHash, windowSeconds],
      );
      const row = result.rows[0];
      if (!row) throw new Error("Rate limiting state was not persisted.");
      const hits = Number(row.hits);
      const windowBucket = Number(row.window_bucket);
      if (!Number.isSafeInteger(hits) || !Number.isSafeInteger(windowBucket)) {
        throw new Error("Rate limiting state was invalid.");
      }
      response.setHeader("RateLimit-Limit", String(maxRequests));
      response.setHeader("RateLimit-Remaining", String(Math.max(0, maxRequests - hits)));
      if (hits > maxRequests) {
        const remainingSeconds = Math.max(
          1,
          Math.ceil((windowBucket + 1) * windowSeconds - Date.now() / 1000),
        );
        response.setHeader("Retry-After", String(remainingSeconds));
        response.status(429).json({
          error: {
            code: "RATE_LIMIT_EXCEEDED",
            message: "Limite de tentativas excedido. Tente novamente mais tarde.",
          },
        });
        return;
      }
      next();
    } catch (error) {
      // Fail closed: do not bypass protection when the shared store is unavailable.
      next(error);
    }
  };
}
