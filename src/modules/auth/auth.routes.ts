import { Router } from "express";

import { createSensitiveRouteRateLimit } from "../../common/middlewares/rate-limit.middleware.js";
import { AuthController } from "./auth.controller.js";
import { createRequireAuthentication } from "./auth.middleware.js";
import type { AuthService } from "./auth.service.js";

export function createAuthRouter(authService: AuthService): Router {
  const router = Router();
  const controller = new AuthController(authService);
  const requireAuthentication = createRequireAuthentication(authService);

  router.post(
    "/login-state",
    createSensitiveRouteRateLimit({ scope: "login-state", maxRequests: 30, windowSeconds: 60 }),
    controller.resolveLoginState,
  );
  router.post(
    "/password-setup",
    createSensitiveRouteRateLimit({ scope: "password-setup", maxRequests: 4, windowSeconds: 60 }),
    controller.setupPassword,
  );
  router.post(
    "/sessions",
    createSensitiveRouteRateLimit({ scope: "sessions", maxRequests: 8, windowSeconds: 60 }),
    controller.createSession,
  );
  router.post(
    "/sessions/refresh",
    createSensitiveRouteRateLimit({ scope: "refresh", maxRequests: 20, windowSeconds: 60 }),
    controller.refreshSession,
  );
  router.delete("/sessions/current", requireAuthentication, controller.deleteSession);
  router.get("/me", requireAuthentication, controller.getMe);
  router.patch(
    "/password",
    requireAuthentication,
    createSensitiveRouteRateLimit({ scope: "password-change", maxRequests: 5, windowSeconds: 300 }),
    controller.changePassword,
  );

  return router;
}
