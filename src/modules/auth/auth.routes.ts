import { Router } from "express";

import { rateLimit } from "express-rate-limit";

import { createPostgresRateLimitOptions } from "../../common/middlewares/rate-limit.middleware.js";
import { AuthController } from "./auth.controller.js";
import { createRequireAuthentication } from "./auth.middleware.js";
import type { AuthService } from "./auth.service.js";

export function createAuthRouter(authService: AuthService): Router {
  const router = Router();
  const controller = new AuthController(authService);
  const requireAuthentication = createRequireAuthentication(authService);

  router.post(
    "/login-state",
    rateLimit(
      createPostgresRateLimitOptions({ scope: "login-state", maxRequests: 30, windowSeconds: 60 }),
    ),
    controller.resolveLoginState,
  );
  router.post(
    "/password-setup",
    rateLimit(
      createPostgresRateLimitOptions({
        scope: "password-setup",
        maxRequests: 4,
        windowSeconds: 60,
      }),
    ),
    controller.setupPassword,
  );
  router.post(
    "/sessions",
    rateLimit(
      createPostgresRateLimitOptions({ scope: "sessions", maxRequests: 8, windowSeconds: 60 }),
    ),
    controller.createSession,
  );
  router.post(
    "/sessions/refresh",
    rateLimit(
      createPostgresRateLimitOptions({ scope: "refresh", maxRequests: 20, windowSeconds: 60 }),
    ),
    controller.refreshSession,
  );
  router.delete("/sessions/current", requireAuthentication, controller.deleteSession);
  router.get("/me", requireAuthentication, controller.getMe);
  router.patch(
    "/password",
    requireAuthentication,
    rateLimit(
      createPostgresRateLimitOptions({
        scope: "password-change",
        maxRequests: 5,
        windowSeconds: 300,
      }),
    ),
    controller.changePassword,
  );

  return router;
}
