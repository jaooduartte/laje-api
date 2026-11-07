import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import { parseDate, requireRecord, requireUuid } from "../../common/validation/common.schema.js";
import {
  createRequireAuthentication,
  requirePermission,
  type AuthenticatedRequest,
} from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";
import { bracketPreviewService } from "./bracket-preview.runtime.js";
import { exactPreviewJobStatus } from "./bracket-preview.service.js";

function requireRequestUserId(request: AuthenticatedRequest): string {
  const userId = request.authPrincipal?.userId;
  if (!userId) {
    throw new ApiError(401, "AUTHENTICATION_REQUIRED", "Autenticação obrigatória.");
  }
  return userId;
}

function requireEstimatedStartTimeSettings(value: unknown): Record<string, boolean> {
  if (value == null) return {};
  const settings = requireRecord(value, "Configuração de horário estimado inválida.");
  return Object.fromEntries(
    Object.entries(settings).map(([sportId, enabled]) => {
      const validSportId = requireUuid(sportId, "sportId");
      if (typeof enabled != "boolean") {
        throw new ApiError(
          422,
          "VALIDATION_ERROR",
          "A configuração de horário estimado deve ser booleana.",
        );
      }
      return [validSportId, enabled];
    }),
  );
}

export function createBracketPreviewRouter(authService: AuthService): Router {
  const router = Router({ mergeParams: true });
  const requireAuthentication = createRequireAuthentication(authService);
  const requirePreviewView = [requireAuthentication, requirePermission("matches", "VIEW")] as const;
  const requirePreviewEdit = [requireAuthentication, requirePermission("matches", "EDIT")] as const;

  router.post("/", ...requirePreviewEdit, async (request, response, next) => {
    try {
      const championshipId = requireUuid(
        (request.params as Record<string, unknown>).championshipId,
        "championshipId",
      );
      const payload = requireRecord(request.body, "Payload de prévia inválido.");
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      const job = await bracketPreviewService.start(championshipId, payload, requestedBy);
      response.status(exactPreviewJobStatus(job) === "QUEUED" ? 202 : 200).json({ data: job });
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
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      const job = await bracketPreviewService.getForChampionship(
        jobId,
        championshipId,
        requestedBy,
      );
      response.status(200).json({ data: job });
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
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      await bracketPreviewService.getForChampionship(jobId, championshipId, requestedBy);
      response.status(200).json({
        data: await bracketPreviewService.getDay(jobId, date, requestedBy),
      });
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
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      await bracketPreviewService.getForChampionship(jobId, championshipId, requestedBy);
      const job = await bracketPreviewService.cancel(jobId, requestedBy);
      response.status(200).json({ data: job });
    } catch (error) {
      next(error);
    }
  });

  router.post("/:jobId/create", ...requirePreviewEdit, async (request, response, next) => {
    try {
      const championshipId = requireUuid(
        (request.params as Record<string, unknown>).championshipId,
        "championshipId",
      );
      const jobId = requireUuid(request.params.jobId, "jobId");
      const requestBody = requireRecord(request.body, "Payload de chaveamento inválido.");
      const usesCreationEnvelope = Object.hasOwn(requestBody, "payload");
      const payload = usesCreationEnvelope
        ? requireRecord(requestBody.payload, "Payload de chaveamento inválido.")
        : requestBody;
      const showEstimatedStartTimeOnCardsBySportId = requireEstimatedStartTimeSettings(
        requestBody.showEstimatedStartTimeOnCardsBySportId,
      );
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      const principal = (request as AuthenticatedRequest).authPrincipal;
      await bracketPreviewService.getForChampionship(jobId, championshipId, requestedBy);
      const editionId = await bracketPreviewService.createBracket(
        jobId,
        championshipId,
        payload,
        requestedBy,
        showEstimatedStartTimeOnCardsBySportId,
        {
          email: principal?.user.email ?? null,
          name: principal?.user.name ?? null,
          role: principal?.user.role ?? null,
        },
      );
      response.status(201).json({ data: { editionId } });
    } catch (error) {
      next(error);
    }
  });

  return router;
}

export function createGlobalBracketPreviewRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requirePreviewView = [requireAuthentication, requirePermission("matches", "VIEW")] as const;
  const requirePreviewEdit = [requireAuthentication, requirePermission("matches", "EDIT")] as const;

  router.get("/:jobId", ...requirePreviewView, async (request, response, next) => {
    try {
      const jobId = requireUuid(request.params.jobId, "jobId");
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      response.status(200).json({ data: await bracketPreviewService.get(jobId, requestedBy) });
    } catch (error) {
      next(error);
    }
  });

  router.get("/:jobId/days/:date", ...requirePreviewView, async (request, response, next) => {
    try {
      const jobId = requireUuid(request.params.jobId, "jobId");
      const date = parseDate(request.params.date, "date");
      if (!date) throw new ApiError(422, "VALIDATION_ERROR", "Data da prévia inválida.");
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      response.status(200).json({
        data: await bracketPreviewService.getDay(jobId, date, requestedBy),
      });
    } catch (error) {
      next(error);
    }
  });

  router.post("/:jobId/cancel", ...requirePreviewEdit, async (request, response, next) => {
    try {
      const jobId = requireUuid(request.params.jobId, "jobId");
      const requestedBy = requireRequestUserId(request as AuthenticatedRequest);
      response.status(200).json({
        data: await bracketPreviewService.cancel(jobId, requestedBy),
      });
    } catch (error) {
      next(error);
    }
  });

  return router;
}
