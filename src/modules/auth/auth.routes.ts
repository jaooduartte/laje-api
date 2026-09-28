import { Router } from "express";

import { AuthController } from "./auth.controller.js";
import { createRequireAuthentication } from "./auth.middleware.js";
import type { AuthService } from "./auth.service.js";

export function createAuthRouter(authService: AuthService): Router {
  const router = Router();
  const controller = new AuthController(authService);
  const requireAuthentication = createRequireAuthentication(authService);

  router.post("/login-state", controller.resolveLoginState);
  router.post("/password-setup", controller.setupPassword);
  router.post("/sessions", controller.createSession);
  router.post("/sessions/refresh", controller.refreshSession);
  router.delete("/sessions/current", requireAuthentication, controller.deleteSession);
  router.get("/me", requireAuthentication, controller.getMe);
  router.patch("/password", requireAuthentication, controller.changePassword);

  return router;
}
