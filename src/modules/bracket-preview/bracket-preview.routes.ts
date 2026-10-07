import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  parseDate,
  requireRecord,
  requireUuid,
} from "../../common/validation/common.schema.js";
import {
  createRequireAuthentication,
  requirePermission,
  type AuthenticatedRequest,
} from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";
import { bracketPreviewService } from "./bracket-preview.runtime.js";
import { serializePreviewJob } from "./bracket-preview.service.js";

export function createBracketPreviewRouter(authService: AuthService): Router {
  const router = Router({ mergeParams: true });
  const requireAuthentication = createRequireAuthentication(authService);
  const requirePreviewView = [
    requireAuthentication,
    requirePermission("bracket_setup", "VIEW"),
  ] as const;
  const requirePreviewEdit = [
    requireAuthentication,
    requirePermission("bracket_setup", "EDIT"),
  ] as const;

  router.post("/", ...requirePreviewEdit, async (request, response, next) => {
    try {
      const championshipId = requireUuid(
        (request.params as Record<string, unknown>).championshipId,
        "championshipId",
      );
      const payload = requireRecord(request.body, "Payload de prévia inválido.");
      const requestedBy =
        (request as AuthenticatedRequest).authPrincipal?.userId ?? null;
      const job = await bracketPreviewService.start(championshipId, payload, requestedBy);
      response.status(job.status === "QUEUED" ? 202 : 200).json({
        data: serializePreviewJob(job),
      });
    } catch (error) {
      next(error);
    }
  });

  router.get("/:jobId", ...requirePreviewView, async (request, response, next) => {
    try {
      const championshipId = requireUuid(
        (request.params as Record<string, unknown>).championshipId,
        "championshipId",
      );
      const jobId = requireUuid(request.params.jobId, "jobId");
      const job = await bracketPreviewService.get(jobId);
      if (job.championshipId !== championshipId) {
        throw new ApiError(404, "PREVIEW_JOB_NOT_FOUND", "Prévia não encontrada.");
      }
      response.status(200).json({ data: serializePreviewJob(job) });
    } catch (error) {
      next(error);
    }
  });

  router.get("/:jobId/days/:date", ...requirePreviewView, async (request, response, next) => {
    try {
      const championshipId = requireUuid(
        (request.params as Record<string, unknown>).championshipId,
        "championshipId",
      );
      const jobId = requireUuid(request.params.jobId, "jobId");
      const date = parseDate(request.params.date, "date");
      if (!date) {
        throw new ApiError(422, "VALIDATION_ERROR", "Data da prévia inválida.");
      }
      const job = await bracketPreviewService.get(jobId);
      if (job.championshipId !== championshipId) {
        throw new ApiError(404, "PREVIEW_JOB_NOT_FOUND", "Prévia não encontrada.");
      }
      response.status(200).json({ data: await bracketPreviewService.getDay(jobId, date) });
    } catch (error) {
      next(error);
    }
  });

  router.post("/:jobId/cancel", ...requirePreviewEdit, async (request, response, next) => {
    try {
      const championshipId = requireUuid(
        (request.params as Record<string, unknown>).championshipId,
        "championshipId",
      );
      const jobId = requireUuid(request.params.jobId, "jobId");
      const existing = await bracketPreviewService.get(jobId);
      if (existing.championshipId !== championshipId) {
        throw new ApiError(404, "PREVIEW_JOB_NOT_FOUND", "Prévia não encontrada.");
      }
      const job = await bracketPreviewService.cancel(jobId);
      response.status(200).json({ data: serializePreviewJob(job) });
    } catch (error) {
      next(error);
    }
  });

  return router;
}
