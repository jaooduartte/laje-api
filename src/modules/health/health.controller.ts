import type { RequestHandler } from "express";

import type { HealthService } from "./health.service.js";

export class HealthController {
  constructor(private readonly healthService: HealthService) {}

  readonly getApplicationHealth: RequestHandler = (_request, response) => {
    response.status(200).json(this.healthService.getApplicationHealth());
  };

  readonly getDatabaseHealth: RequestHandler = async (_request, response) => {
    const health = await this.healthService.getDatabaseHealth();
    const statusCode = health.status === "ok" ? 200 : 503;

    response.status(statusCode).json(health);
  };
}
