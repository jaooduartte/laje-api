import { Router } from "express";

import { database } from "../database/index.js";
import { createHealthRouter } from "../modules/health/health.routes.js";
import { HealthService } from "../modules/health/health.service.js";

export const apiRouter = Router();

const healthService = new HealthService(database);

apiRouter.get("/", (_request, response) => {
  response.status(200).json({
    service: "laje-api",
    version: "v1",
    status: "ready",
  });
});

apiRouter.use("/health", createHealthRouter(healthService));
