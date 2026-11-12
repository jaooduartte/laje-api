import type { NextFunction, Request, Response } from "express";

import { ApiError } from "../errors/api-error.js";

export function errorHandler(
  error: unknown,
  request: Request,
  response: Response,
  _next: NextFunction,
): void {
  if (error instanceof ApiError) {
    response.status(error.statusCode).json({
      error: {
        code: error.code,
        message: error.message,
        ...(error.details ? { details: error.details } : {}),
      },
    });
    return;
  }

  // Do not emit exception messages, stacks or request payloads into CloudWatch.
  console.error(
    JSON.stringify({
      event: "unhandled_exception",
      requestId: response.getHeader("x-request-id") ?? null,
      errorType: error instanceof Error ? error.name : "UnknownError",
      method: request.method,
      route: typeof request.route?.path === "string" ? request.route.path : "unmatched",
    }),
  );
  response.status(500).json({
    error: {
      code: "INTERNAL_SERVER_ERROR",
      message: "An unexpected error occurred.",
    },
  });
}
