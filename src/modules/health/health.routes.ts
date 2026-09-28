import { Router } from "express";

import { HealthController } from "./health.controller.js";
import type { HealthService } from "./health.service.js";

export function createHealthRouter(healthService: HealthService): Router {
  const router = Router();
  const controller = new HealthController(healthService);

  router.get("/", controller.getApplicationHealth);
  router.get("/database", controller.getDatabaseHealth);

  return router;
}
