import { createHash } from "node:crypto";
import type { Request, Response } from "express";
import type { Store } from "express-rate-limit";

import { environment } from "../../config/environment.js";
import { database } from "../../database/index.js";
import type { DatabaseQueryExecutor } from "../../database/types.js";

export interface SensitiveRateLimitOptions {
  scope: string;
  maxRequests: number;
  windowSeconds: number;
  executor?: DatabaseQueryExecutor;
  enabled?: boolean;
}

/** Atomic limiter store shared by all ECS tasks through PostgreSQL 17. */
export class PostgresRateLimitStore implements Store {
  readonly localKeys = false;

  constructor(
    private readonly scope: string,
    private readonly windowSeconds: number,
    private readonly executor: DatabaseQueryExecutor = database,
  ) {}

  private hash(key: string): string {
    return createHash("sha256").update(this.scope).update("\0").update(key).digest("hex");
  }

  async increment(key: string) {
    const result = await this.executor.query<{ hits: number; window_bucket: number }>(
      `INSERT INTO public.api_rate_limit_windows AS bucket
         (key_hash, window_bucket, hits)
       VALUES ($1, floor(extract(epoch FROM clock_timestamp()) / $2)::bigint, 1)
       ON CONFLICT (key_hash) DO UPDATE SET
         hits = CASE WHEN bucket.window_bucket = EXCLUDED.window_bucket
                     THEN bucket.hits + 1 ELSE 1 END,
         window_bucket = GREATEST(bucket.window_bucket, EXCLUDED.window_bucket)
       RETURNING hits, window_bucket`,
      [this.hash(key), this.windowSeconds],
    );
    const row = result.rows[0];
    if (!row) throw new Error("Rate limiting state was not persisted.");
    const totalHits = Number(row.hits);
    const windowBucket = Number(row.window_bucket);
    if (!Number.isSafeInteger(totalHits) || !Number.isSafeInteger(windowBucket)) {
      throw new Error("Rate limiting state was invalid.");
    }
    return {
      totalHits,
      resetTime: new Date((windowBucket + 1) * this.windowSeconds * 1000),
    };
  }

  async decrement(key: string): Promise<void> {
    await this.executor.query(
      "UPDATE public.api_rate_limit_windows SET hits = GREATEST(1, hits - 1) WHERE key_hash = $1",
      [this.hash(key)],
    );
  }

  async resetKey(key: string): Promise<void> {
    await this.executor.query("DELETE FROM public.api_rate_limit_windows WHERE key_hash = $1", [
      this.hash(key),
    ]);
  }
}

/**
 * The express-rate-limit package is used directly at Express route declarations,
 * allowing CodeQL to recognize rate-limited request handlers.
 */
export function createPostgresRateLimitOptions(options: SensitiveRateLimitOptions) {
  const { scope, maxRequests, windowSeconds } = options;
  const enabled = options.enabled ?? environment.auth.enabled;
  if (
    !/^[a-z][a-z0-9-]{1,63}$/.test(scope) ||
    !Number.isSafeInteger(maxRequests) ||
    maxRequests < 1 ||
    !Number.isSafeInteger(windowSeconds) ||
    windowSeconds < 1
  ) {
    throw new Error("Invalid rate limit configuration.");
  }

  return {
    windowMs: windowSeconds * 1000,
    limit: maxRequests,
    standardHeaders: "draft-6" as const,
    legacyHeaders: false,
    store: new PostgresRateLimitStore(scope, windowSeconds, options.executor),
    skip: (_request: Request) => !enabled,
    handler: (_request: Request, response: Response) => {
      response.status(429).json({
        error: {
          code: "RATE_LIMIT_EXCEEDED",
          message: "Limite de tentativas excedido. Tente novamente mais tarde.",
        },
      });
    },
  };
}
