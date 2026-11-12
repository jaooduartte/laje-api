import { randomUUID } from "node:crypto";
import type { NextFunction, Request, Response } from "express";

/**
 * LAJE-40: correlate 5xx responses with a short, privacy-safe CloudWatch record.
 * HTTP API Gateway access logs cover all statuses without capturing URLs or payloads.
 */
export function observeRequests(request: Request, response: Response, next: NextFunction): void {
  const requestId = randomUUID();
  const started = process.hrtime.bigint();
  response.setHeader("x-request-id", requestId);

  response.once("finish", () => {
    if (response.statusCode < 500) return;

    const route = request.route?.path;
    console.error(
      JSON.stringify({
        event: "http_request_failed",
        requestId,
        method: request.method,
        route: typeof route === "string" ? route : "unmatched",
        status: response.statusCode,
        durationMs: Math.round(Number(process.hrtime.bigint() - started) / 1_000_000),
      }),
    );
  });

  next();
}
