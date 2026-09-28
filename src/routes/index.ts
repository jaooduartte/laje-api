import { Router } from "express";

import { environment } from "../config/environment.js";
import { database } from "../database/index.js";
import { AuthRepository } from "../modules/auth/auth.repository.js";
import { createAuthRouter } from "../modules/auth/auth.routes.js";
import { AuthService } from "../modules/auth/auth.service.js";
import { createHealthRouter } from "../modules/health/health.routes.js";
import { HealthService } from "../modules/health/health.service.js";

export const apiRouter = Router();

const healthService = new HealthService(database);
const authRepository = new AuthRepository(database);
const authService = new AuthService(authRepository, {
  enabled: environment.auth.enabled,
  jwtSecret: environment.auth.jwtSecret,
  jwtExpiresIn: environment.auth.jwtExpiresIn,
  refreshExpiresInDays: 30,
  secureCookies: environment.nodeEnv === "production",
});

apiRouter.get("/", (_request, response) => {
  response.status(200).json({
    service: "laje-api",
    version: "v1",
    status: "ready",
  });
});

apiRouter.use("/health", createHealthRouter(healthService));
apiRouter.use("/auth", createAuthRouter(authService));
