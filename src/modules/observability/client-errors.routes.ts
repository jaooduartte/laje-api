import { Router } from "express";
import { rateLimit } from "express-rate-limit";

const allowedKinds = new Set([
  "javascript",
  "promise",
  "react-render",
  "api-network",
  "api-http",
]);
const allowedFields = new Set(["kind", "status", "code", "requestId"]);
const errorCodePattern = /^[A-Z][A-Z0-9_]{0,63}$/;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/**
 * Accepts only enumerated, bounded telemetry fields. Never ingest error messages,
 * stacks, URLs, query strings, credentials, cookies or user-supplied metadata.
 */
export function createClientErrorsRouter(allowedOrigins: readonly string[]): Router {
  const router = Router();

  router.post(
    "/",
    rateLimit({
      windowMs: 60_000,
      limit: 20,
      standardHeaders: "draft-6",
      legacyHeaders: false,
      // The container has one trusted proxy hop. Do not trust arbitrary XFF for quota keys.
      validate: { trustProxy: false, xForwardedForHeader: false },
      handler: (_request, response) => {
        response.status(429).json({ error: { code: "RATE_LIMIT_EXCEEDED" } });
      },
    }),
    (request, response) => {
      const origin = request.get("origin");
      if (!origin || !allowedOrigins.includes(origin)) {
        response.status(403).json({ error: { code: "ORIGIN_NOT_ALLOWED" } });
        return;
      }

      const body: unknown = request.body;
      if (!body || typeof body !== "object" || Array.isArray(body)) {
        response.status(400).json({ error: { code: "INVALID_TELEMETRY" } });
        return;
      }

      const fields = body as Record<string, unknown>;
      if (
        !Object.keys(fields).every((field) => allowedFields.has(field)) ||
        typeof fields.kind !== "string" ||
        !allowedKinds.has(fields.kind) ||
        (fields.status !== undefined &&
          (!Number.isInteger(fields.status) ||
            (fields.status as number) < 500 ||
            (fields.status as number) > 599)) ||
        (fields.code !== undefined &&
          (typeof fields.code !== "string" || !errorCodePattern.test(fields.code))) ||
        (fields.requestId !== undefined &&
          (typeof fields.requestId !== "string" || !uuidPattern.test(fields.requestId)))
      ) {
        response.status(400).json({ error: { code: "INVALID_TELEMETRY" } });
        return;
      }

      console.warn(
        JSON.stringify({
          event: "frontend_error",
          kind: fields.kind,
          status: fields.status ?? null,
          code: fields.code ?? null,
          requestId: fields.requestId ?? null,
        }),
      );
      response.status(204).end();
    },
  );

  return router;
}
