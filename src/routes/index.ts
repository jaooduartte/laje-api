import { Router } from "express";

import { environment } from "../config/environment.js";
import { database } from "../database/index.js";
import { AuthRepository } from "../modules/auth/auth.repository.js";
import { createAdminRuntimeRouter } from "../modules/admin-runtime/admin-runtime.routes.js";
import { createAuthRouter } from "../modules/auth/auth.routes.js";
import { AuthService } from "../modules/auth/auth.service.js";
import { createChampionshipsRouter } from "../modules/championships/championships.routes.js";
import { createHealthRouter } from "../modules/health/health.routes.js";
import { HealthService } from "../modules/health/health.service.js";
import { createLeagueEventConflictsRouter } from "../modules/league-events/league-event-conflicts.routes.js";
import { createLeagueEventsRouter } from "../modules/league-events/league-events.routes.js";
import { createMatchesRouter } from "../modules/matches/matches.routes.js";
import { createPublicAccessRouter } from "../modules/public-access/public-access.routes.js";
import { createPublicRuntimeRouter } from "../modules/public-runtime/public-runtime.routes.js";

export const apiRouter = Router();

const healthService = new HealthService(database);
const authRepository = new AuthRepository(database);
const authService = new AuthService(authRepository, {
  enabled: environment.auth.enabled,
  jwtSecret: environment.auth.jwtSecret,
  jwtExpiresIn: environment.auth.jwtExpiresIn,
  refreshExpiresInDays: environment.auth.refreshExpiresInDays,
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
apiRouter.use("/admin-runtime", createAdminRuntimeRouter(authService));
apiRouter.use("/matches", createMatchesRouter(authService));
apiRouter.use("/championships", createChampionshipsRouter(authService));
apiRouter.use("/league-events", createLeagueEventConflictsRouter());
apiRouter.use("/league-events", createLeagueEventsRouter(authService));
apiRouter.use("/public", createPublicAccessRouter(authService));
apiRouter.use("/public-runtime", createPublicRuntimeRouter());
