import { Router } from "express";

import type { DatabaseQueryAdapter } from "../database/types.js";
import { checkDatabaseConnection, database } from "../database/index.js";
import { createAuthRouter } from "../modules/auth/auth.routes.js";
import { AuthRepository } from "../modules/auth/auth.repository.js";
import { AuthService } from "../modules/auth/auth.service.js";
import { createChampionshipsRouter } from "../modules/championships/championships.routes.js";
import { HealthController } from "../modules/health/health.controller.js";
import { HealthService } from "../modules/health/health.service.js";
import { healthRoutes } from "../modules/health/health.routes.js";
import { createMatchesRouter } from "../modules/matches/matches.routes.js";

export const apiRouter = Router();

const healthService = new HealthService(checkDatabaseConnection);
const healthController = new HealthController(healthService);
const authRepository = new AuthRepository(database as DatabaseQueryAdapter);
const authService = new AuthService(authRepository);

apiRouter.get("/", (_request, response) => {
  response.status(200).json({
    service: "laje-api",
    version: "v1",
    status: "ok",
    health: {
      liveness: "/health/live",
      readiness: "/health/ready",
    },
  });
});

apiRouter.use("/", healthRoutes(healthController));
apiRouter.use("/auth", createAuthRouter(authService));
apiRouter.use("/matches", createMatchesRouter(authService));
apiRouter.use("/championships", createChampionshipsRouter(authService));
