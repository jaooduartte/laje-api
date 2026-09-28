import type { NextFunction, Request, RequestHandler, Response } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import type { AuthService } from "./auth.service.js";
import { readBearerToken } from "./auth.schema.js";
import type { AuthPrincipal } from "./auth.types.js";

export interface AuthenticatedRequest extends Request {
  authPrincipal?: AuthPrincipal;
}

export function createRequireAuthentication(authService: AuthService): RequestHandler {
  return async (request: Request, _response: Response, next: NextFunction) => {
    try {
      const principal = await authService.authenticateAccessToken(
        readBearerToken(request.header("authorization")),
      );
      (request as AuthenticatedRequest).authPrincipal = principal;
      next();
    } catch (error) {
      next(error);
    }
  };
}

export function requirePermission(scope: string, requiredLevel: "VIEW" | "EDIT"): RequestHandler {
  return (request: Request, _response: Response, next: NextFunction) => {
    const principal = (request as AuthenticatedRequest).authPrincipal;
    if (!principal) {
      next(new ApiError(401, "ACCESS_TOKEN_REQUIRED", "Authentication is required."));
      return;
    }

    const permission = principal.user.permissions.find((item) => item.scope === scope);
    const allowed =
      requiredLevel === "EDIT"
        ? permission?.level === "EDIT"
        : permission?.level === "VIEW" || permission?.level === "EDIT";
    if (!allowed) {
      next(new ApiError(403, "PERMISSION_DENIED", "Administrative permission is insufficient."));
      return;
    }
    next();
  };
}
