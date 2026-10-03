import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalBoolean,
  optionalString,
  requireEnum,
  requireInteger,
  requireRecord,
  requireString,
  requireUuid,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../database/types.js";
import {
  createRequireAuthentication,
  requirePermission,
  type AuthenticatedRequest,
} from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";

const FILTER_MODES = ["GLOBAL", "BY_CHAMPIONSHIP_YEAR"] as const;
const ANNOUNCEMENT_TYPES = ["IMPROVEMENT", "NOTICE", "PROBLEM"] as const;

interface LinkFilterInput {
  championshipId: string;
  seasonYear: number;
}

interface LinkItemInput {
  sectionId: string;
  displayName: string;
  url: string;
  sortOrder: number;
  isActive: boolean;
  filterMode: (typeof FILTER_MODES)[number];
  filters: LinkFilterInput[];
}

const SETTINGS_SELECT = `SELECT
  id,
  is_public_access_blocked AS "isPublicAccessBlocked",
  is_live_page_blocked AS "isLivePageBlocked",
  is_championships_page_blocked AS "isChampionshipsPageBlocked",
  is_schedule_page_blocked AS "isSchedulePageBlocked",
  is_league_calendar_page_blocked AS "isLeagueCalendarPageBlocked",
  is_links_page_blocked AS "isLinksPageBlocked",
  blocked_message AS "blockedMessage",
  announcement_message AS "announcementMessage",
  announcement_content AS "announcementContent",
  announcement_type AS "announcementType",
  updated_by AS "updatedBy",
  created_at::text AS "createdAt",
  updated_at::text AS "updatedAt"
FROM public.public_page_access_settings WHERE id = 1`;

const SECTION_SELECT = `SELECT
  s.id,
  s.name,
  s.description,
  s.sort_order AS "sortOrder",
  s.is_active AS "isActive",
  s.created_at::text AS "createdAt",
  s.updated_at::text AS "updatedAt",
  COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', i.id,
        'sectionId', i.section_id,
        'displayName', i.display_name,
        'url', i.url,
        'sortOrder', i.sort_order,
        'isActive', i.is_active,
        'filterMode', i.filter_mode,
        'createdAt', i.created_at::text,
        'updatedAt', i.updated_at::text,
        'publicLinkItemFilters', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', f.id,
              'publicLinkItemId', f.public_link_item_id,
              'championshipId', f.championship_id,
              'seasonYear', f.season_year,
              'createdAt', f.created_at::text
            ) ORDER BY f.season_year, f.championship_id
          )
          FROM public.public_link_item_filters f
          WHERE f.public_link_item_id = i.id
        ), '[]'::jsonb)
      ) ORDER BY i.sort_order, i.created_at, i.id
    )
    FROM public.public_link_items i
    WHERE i.section_id = s.id
      AND ($1::boolean OR i.is_active)
  ), '[]'::jsonb) AS "publicLinkItems"
FROM public.public_link_sections s
WHERE ($1::boolean OR s.is_active)
ORDER BY s.sort_order, s.created_at, s.id`;

async function insertAudit(
  executor: DatabaseQueryExecutor,
  request: AuthenticatedRequest,
  actionType: "INSERT" | "UPDATE" | "DELETE",
  resourceTable: string,
  recordId: string,
  description: string,
  oldData: DatabaseRow | null,
  newData: DatabaseRow | null,
): Promise<void> {
  const principal = request.authPrincipal;
  await executor.query(
    `INSERT INTO public.admin_action_logs
      (actor_user_id, actor_email, actor_role, action_type, resource_table, record_id, description, old_data, new_data, metadata, actor_name)
     VALUES ($1, $2, $3::public.app_role, $4::public.admin_action_type, $5, $6, $7, $8::jsonb, $9::jsonb, $10::jsonb, $11)`,
    [
      principal?.userId ?? null,
      principal?.user.email ?? null,
      principal?.user.role ?? null,
      actionType,
      resourceTable,
      recordId,
      description,
      oldData ? JSON.stringify(oldData) : null,
      newData ? JSON.stringify(newData) : null,
      JSON.stringify({ source: "laje-api", task: "LAJE-87" }),
      principal?.user.profile?.name ?? null,
    ],
  );
}

async function getSection(executor: DatabaseQueryExecutor, sectionId: string) {
  const result = await executor.query(
    `SELECT id, name, description, sort_order AS "sortOrder", is_active AS "isActive",
      created_at::text AS "createdAt", updated_at::text AS "updatedAt"
     FROM public.public_link_sections WHERE id = $1`,
    [sectionId],
  );
  return result.rows[0] ?? null;
}

async function getItem(executor: DatabaseQueryExecutor, itemId: string) {
  const result = await executor.query(
    `SELECT i.id, i.section_id AS "sectionId", i.display_name AS "displayName", i.url,
      i.sort_order AS "sortOrder", i.is_active AS "isActive", i.filter_mode AS "filterMode",
      i.created_at::text AS "createdAt", i.updated_at::text AS "updatedAt",
      COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', f.id,
        'publicLinkItemId', f.public_link_item_id,
        'championshipId', f.championship_id,
        'seasonYear', f.season_year,
        'createdAt', f.created_at::text
      ) ORDER BY f.season_year, f.championship_id)
      FROM public.public_link_item_filters f WHERE f.public_link_item_id = i.id), '[]'::jsonb) AS "publicLinkItemFilters"
     FROM public.public_link_items i WHERE i.id = $1`,
    [itemId],
  );
  return result.rows[0] ?? null;
}

function parseSectionInput(body: unknown) {
  const payload = requireRecord(body);
  return {
    name: requireString(payload.name, "name", 160),
    description:
      payload.description === null
        ? null
        : (optionalString(payload.description, "description", 1000) ?? null),
    sortOrder: requireInteger(payload.sortOrder, "sortOrder", { min: 1, max: 10000 }),
    isActive: optionalBoolean(payload.isActive, "isActive") ?? true,
  };
}

function parseAbsoluteHttpUrl(value: unknown): string {
  const raw = requireString(value, "url", 2048);
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "Informe uma URL absoluta válida começando com http:// ou https://.",
    );
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "Informe uma URL absoluta válida começando com http:// ou https://.",
    );
  }
  return raw;
}

function parseFilters(
  value: unknown,
  filterMode: (typeof FILTER_MODES)[number],
): LinkFilterInput[] {
  if (filterMode === "GLOBAL") return [];
  if (!Array.isArray(value) || value.length === 0) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "Adicione ao menos um filtro de campeonato e ano para esse link.",
    );
  }
  const unique = new Map<string, LinkFilterInput>();
  value.forEach((rawFilter, index) => {
    const filter = requireRecord(rawFilter, `Filtro ${index + 1} inválido.`);
    const championshipId = requireUuid(filter.championshipId, `filters[${index}].championshipId`);
    const seasonYear = requireInteger(filter.seasonYear, `filters[${index}].seasonYear`, {
      min: 2000,
      max: 9999,
    });
    unique.set(`${championshipId}:${seasonYear}`, { championshipId, seasonYear });
  });
  return [...unique.values()];
}

function parseItemInput(body: unknown): LinkItemInput {
  const payload = requireRecord(body);
  const filterMode = requireEnum(payload.filterMode, "filterMode", FILTER_MODES);
  return {
    sectionId: requireUuid(payload.sectionId, "sectionId"),
    displayName: requireString(payload.displayName, "displayName", 255),
    url: parseAbsoluteHttpUrl(payload.url),
    sortOrder: requireInteger(payload.sortOrder, "sortOrder", { min: 1, max: 10000 }),
    isActive: optionalBoolean(payload.isActive, "isActive") ?? true,
    filterMode,
    filters: parseFilters(payload.filters, filterMode),
  };
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

function normalizeAnnouncementContent(value: unknown): {
  message: string | null;
  content: Record<string, unknown> | null;
} {
  if (value == null) return { message: null, content: null };
  const content = requireRecord(value, "Conteúdo do aviso inválido.");
  if (content.version !== 1 || !Array.isArray(content.segments)) {
    throw new ApiError(422, "VALIDATION_ERROR", "Conteúdo do aviso inválido.");
  }
  const segments = content.segments.map((rawSegment, index) => {
    const segment = requireRecord(rawSegment, `Segmento ${index + 1} do aviso inválido.`);
    if (typeof segment.text !== "string") {
      throw new ApiError(422, "VALIDATION_ERROR", "Conteúdo do aviso inválido.");
    }
    for (const property of ["bold", "italic", "underline"] as const) {
      if (segment[property] !== undefined && typeof segment[property] !== "boolean") {
        throw new ApiError(422, "VALIDATION_ERROR", "Conteúdo do aviso inválido.");
      }
    }
    const normalized: Record<string, unknown> = { text: normalizeWhitespace(segment.text) };
    if (segment.bold === true) normalized.bold = true;
    if (segment.italic === true) normalized.italic = true;
    if (segment.underline === true) normalized.underline = true;
    return normalized;
  });
  const message = normalizeWhitespace(segments.map((segment) => String(segment.text)).join(""));
  return message.length === 0
    ? { message: null, content: null }
    : { message, content: { version: 1, segments } };
}

function parseSettingsInput(body: unknown) {
  const payload = requireRecord(body);
  const legacyMessage =
    payload.announcementMessage === null
      ? null
      : (optionalString(payload.announcementMessage, "announcementMessage", 4000) ?? null);
  const normalized =
    payload.announcementContent === undefined
      ? legacyMessage
        ? {
            message: normalizeWhitespace(legacyMessage),
            content: { version: 1, segments: [{ text: normalizeWhitespace(legacyMessage) }] },
          }
        : { message: null, content: null }
      : normalizeAnnouncementContent(payload.announcementContent);
  return {
    isPublicAccessBlocked:
      optionalBoolean(payload.isPublicAccessBlocked, "isPublicAccessBlocked") ?? false,
    isLivePageBlocked: optionalBoolean(payload.isLivePageBlocked, "isLivePageBlocked") ?? false,
    isChampionshipsPageBlocked:
      optionalBoolean(payload.isChampionshipsPageBlocked, "isChampionshipsPageBlocked") ?? false,
    isSchedulePageBlocked:
      optionalBoolean(payload.isSchedulePageBlocked, "isSchedulePageBlocked") ?? false,
    isLeagueCalendarPageBlocked:
      optionalBoolean(payload.isLeagueCalendarPageBlocked, "isLeagueCalendarPageBlocked") ?? false,
    isLinksPageBlocked: optionalBoolean(payload.isLinksPageBlocked, "isLinksPageBlocked") ?? false,
    blockedMessage:
      payload.blockedMessage === null
        ? null
        : (optionalString(payload.blockedMessage, "blockedMessage", 2000) ?? null),
    announcementMessage: normalized.message,
    announcementContent: normalized.content,
    announcementType:
      payload.announcementType === undefined
        ? "NOTICE"
        : requireEnum(payload.announcementType, "announcementType", ANNOUNCEMENT_TYPES),
  };
}

async function persistFilters(
  executor: DatabaseQueryExecutor,
  itemId: string,
  input: LinkItemInput,
): Promise<void> {
  await executor.query(
    "DELETE FROM public.public_link_item_filters WHERE public_link_item_id = $1",
    [itemId],
  );
  if (input.filterMode === "GLOBAL") return;

  const championshipIds = [...new Set(input.filters.map((filter) => filter.championshipId))];
  const championships = await executor.query(
    "SELECT id FROM public.championships WHERE id = ANY($1::uuid[])",
    [championshipIds],
  );
  if (championships.rows.length !== championshipIds.length) {
    throw new ApiError(
      422,
      "CHAMPIONSHIP_NOT_FOUND",
      "Campeonato informado no filtro não foi encontrado.",
    );
  }
  for (const filter of input.filters) {
    await executor.query(
      `INSERT INTO public.public_link_item_filters(public_link_item_id, championship_id, season_year)
       VALUES ($1, $2, $3)
       ON CONFLICT (public_link_item_id, championship_id, season_year) DO NOTHING`,
      [itemId, filter.championshipId, filter.seasonYear],
    );
  }
}

async function normalizeSectionOrderAfterDelete(
  executor: DatabaseQueryExecutor,
  deletedSortOrder: number,
) {
  await executor.query(
    "UPDATE public.public_link_sections SET sort_order = sort_order - 1 WHERE sort_order > $1",
    [deletedSortOrder],
  );
}

export function createPublicAccessRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireLinksView = [requireAuthentication, requirePermission("links", "VIEW")] as const;
  const requireLinksEdit = [requireAuthentication, requirePermission("links", "EDIT")] as const;
  const requireSettingsEdit = [
    requireAuthentication,
    requirePermission("settings", "EDIT"),
  ] as const;

  router.get("/settings", async (_request, response, next) => {
    try {
      const result = await database.query(SETTINGS_SELECT);
      response.status(200).json({ data: result.rows[0] ?? null });
    } catch (error) {
      next(error);
    }
  });

  router.put("/settings", ...requireSettingsEdit, async (request, response, next) => {
    try {
      const input = parseSettingsInput(request.body);
      const updatedBy = (request as AuthenticatedRequest).authPrincipal?.userId ?? null;
      const result = await database.transaction(async (transaction) => {
        const previousResult = await transaction.query(SETTINGS_SELECT);
        const previous = previousResult.rows[0] ?? null;
        await transaction.query(
          `INSERT INTO public.public_page_access_settings(
            id, is_public_access_blocked, is_live_page_blocked, is_championships_page_blocked,
            is_schedule_page_blocked, is_league_calendar_page_blocked, is_links_page_blocked,
            blocked_message, announcement_message, announcement_content, announcement_type, updated_by
          ) VALUES (1, $1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11)
          ON CONFLICT(id) DO UPDATE SET
            is_public_access_blocked = EXCLUDED.is_public_access_blocked,
            is_live_page_blocked = EXCLUDED.is_live_page_blocked,
            is_championships_page_blocked = EXCLUDED.is_championships_page_blocked,
            is_schedule_page_blocked = EXCLUDED.is_schedule_page_blocked,
            is_league_calendar_page_blocked = EXCLUDED.is_league_calendar_page_blocked,
            is_links_page_blocked = EXCLUDED.is_links_page_blocked,
            blocked_message = EXCLUDED.blocked_message,
            announcement_message = EXCLUDED.announcement_message,
            announcement_content = EXCLUDED.announcement_content,
            announcement_type = EXCLUDED.announcement_type,
            updated_by = EXCLUDED.updated_by,
            updated_at = now()`,
          [
            input.isPublicAccessBlocked,
            input.isLivePageBlocked,
            input.isChampionshipsPageBlocked,
            input.isSchedulePageBlocked,
            input.isLeagueCalendarPageBlocked,
            input.isLinksPageBlocked,
            input.blockedMessage,
            input.announcementMessage,
            input.announcementContent ? JSON.stringify(input.announcementContent) : null,
            input.announcementType,
            updatedBy,
          ],
        );
        const currentResult = await transaction.query(SETTINGS_SELECT);
        const current = currentResult.rows[0] ?? null;
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "UPDATE",
          "public.public_page_access_settings",
          "1",
          input.isPublicAccessBlocked
            ? "Bloqueou acesso geral às telas públicas"
            : "Atualizou bloqueio por telas públicas",
          previous,
          current,
        );
        return current;
      });
      response.status(200).json({ data: result });
    } catch (error) {
      next(error);
    }
  });

  router.get("/links", async (_request, response, next) => {
    try {
      const result = await database.query(SECTION_SELECT, [false]);
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.get("/links/admin", ...requireLinksView, async (_request, response, next) => {
    try {
      const result = await database.query(SECTION_SELECT, [true]);
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.post("/link-sections", ...requireLinksEdit, async (request, response, next) => {
    try {
      const input = parseSectionInput(request.body);
      const section = await database.transaction(async (transaction) => {
        const maxResult = await transaction.query(
          "SELECT COALESCE(MAX(sort_order), 0)::integer AS max FROM public.public_link_sections",
        );
        const max = Number(maxResult.rows[0]?.max ?? 0);
        const sortOrder = Math.min(input.sortOrder, max + 1);
        await transaction.query(
          "UPDATE public.public_link_sections SET sort_order = sort_order + 1 WHERE sort_order >= $1",
          [sortOrder],
        );
        const inserted = await transaction.query(
          `INSERT INTO public.public_link_sections(name, description, sort_order, is_active)
           VALUES ($1, $2, $3, $4) RETURNING id`,
          [input.name, input.description, sortOrder, input.isActive],
        );
        const sectionId = String(inserted.rows[0]!.id);
        const current = await getSection(transaction, sectionId);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "INSERT",
          "public.public_link_sections",
          sectionId,
          "Criou uma seção de links públicos",
          null,
          current,
        );
        return current;
      });
      response.status(201).json({ data: section });
    } catch (error) {
      next(error);
    }
  });

  router.put("/link-sections/:sectionId", ...requireLinksEdit, async (request, response, next) => {
    try {
      const sectionId = requireUuid(request.params.sectionId, "sectionId");
      const input = parseSectionInput(request.body);
      const section = await database.transaction(async (transaction) => {
        const previous = await getSection(transaction, sectionId);
        if (!previous)
          throw new ApiError(
            404,
            "PUBLIC_LINK_SECTION_NOT_FOUND",
            "Seção de links não encontrada.",
          );
        const oldOrder = Number(previous.sortOrder);
        const maxResult = await transaction.query(
          "SELECT COALESCE(MAX(sort_order), 1)::integer AS max FROM public.public_link_sections WHERE id <> $1",
          [sectionId],
        );
        const max = Number(maxResult.rows[0]?.max ?? 1);
        const sortOrder = Math.min(input.sortOrder, Math.max(max + 1, 1));
        if (sortOrder < oldOrder) {
          await transaction.query(
            `UPDATE public.public_link_sections SET sort_order = sort_order + 1
             WHERE id <> $1 AND sort_order >= $2 AND sort_order < $3`,
            [sectionId, sortOrder, oldOrder],
          );
        } else if (sortOrder > oldOrder) {
          await transaction.query(
            `UPDATE public.public_link_sections SET sort_order = sort_order - 1
             WHERE id <> $1 AND sort_order <= $2 AND sort_order > $3`,
            [sectionId, sortOrder, oldOrder],
          );
        }
        await transaction.query(
          `UPDATE public.public_link_sections SET name = $2, description = $3, sort_order = $4,
             is_active = $5, updated_at = now() WHERE id = $1`,
          [sectionId, input.name, input.description, sortOrder, input.isActive],
        );
        const current = await getSection(transaction, sectionId);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "UPDATE",
          "public.public_link_sections",
          sectionId,
          "Atualizou uma seção de links públicos",
          previous,
          current,
        );
        return current;
      });
      response.status(200).json({ data: section });
    } catch (error) {
      next(error);
    }
  });

  router.delete(
    "/link-sections/:sectionId",
    ...requireLinksEdit,
    async (request, response, next) => {
      try {
        const sectionId = requireUuid(request.params.sectionId, "sectionId");
        await database.transaction(async (transaction) => {
          const previous = await getSection(transaction, sectionId);
          if (!previous)
            throw new ApiError(
              404,
              "PUBLIC_LINK_SECTION_NOT_FOUND",
              "Seção de links não encontrada.",
            );
          const itemCount = await transaction.query(
            "SELECT count(*)::integer AS count FROM public.public_link_items WHERE section_id = $1",
            [sectionId],
          );
          if (Number(itemCount.rows[0]?.count ?? 0) > 0) {
            throw new ApiError(
              409,
              "PUBLIC_LINK_SECTION_NOT_EMPTY",
              "Remova os links da seção antes de excluí-la.",
            );
          }
          await transaction.query("DELETE FROM public.public_link_sections WHERE id = $1", [
            sectionId,
          ]);
          await normalizeSectionOrderAfterDelete(transaction, Number(previous.sortOrder));
          await insertAudit(
            transaction,
            request as AuthenticatedRequest,
            "DELETE",
            "public.public_link_sections",
            sectionId,
            "Excluiu uma seção de links públicos",
            previous,
            null,
          );
        });
        response.status(204).end();
      } catch (error) {
        next(error);
      }
    },
  );

  router.post("/link-items", ...requireLinksEdit, async (request, response, next) => {
    try {
      const input = parseItemInput(request.body);
      const item = await database.transaction(async (transaction) => {
        if (!(await getSection(transaction, input.sectionId))) {
          throw new ApiError(
            404,
            "PUBLIC_LINK_SECTION_NOT_FOUND",
            "Seção de links não encontrada.",
          );
        }
        const maxResult = await transaction.query(
          "SELECT COALESCE(MAX(sort_order), 0)::integer AS max FROM public.public_link_items WHERE section_id = $1",
          [input.sectionId],
        );
        const max = Number(maxResult.rows[0]?.max ?? 0);
        const sortOrder = Math.min(input.sortOrder, max + 1);
        await transaction.query(
          `UPDATE public.public_link_items SET sort_order = sort_order + 1
           WHERE section_id = $1 AND sort_order >= $2`,
          [input.sectionId, sortOrder],
        );
        const inserted = await transaction.query(
          `INSERT INTO public.public_link_items(section_id, display_name, url, sort_order, is_active, filter_mode)
           VALUES ($1, $2, $3, $4, $5, $6::public.public_link_filter_mode) RETURNING id`,
          [
            input.sectionId,
            input.displayName,
            input.url,
            sortOrder,
            input.isActive,
            input.filterMode,
          ],
        );
        const itemId = String(inserted.rows[0]!.id);
        await persistFilters(transaction, itemId, input);
        const current = await getItem(transaction, itemId);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "INSERT",
          "public.public_link_items",
          itemId,
          "Criou um link público",
          null,
          current,
        );
        return current;
      });
      response.status(201).json({ data: item });
    } catch (error) {
      next(error);
    }
  });

  router.put("/link-items/:itemId", ...requireLinksEdit, async (request, response, next) => {
    try {
      const itemId = requireUuid(request.params.itemId, "itemId");
      const input = parseItemInput(request.body);
      const item = await database.transaction(async (transaction) => {
        const previous = await getItem(transaction, itemId);
        if (!previous)
          throw new ApiError(404, "PUBLIC_LINK_ITEM_NOT_FOUND", "Link público não encontrado.");
        if (!(await getSection(transaction, input.sectionId))) {
          throw new ApiError(
            404,
            "PUBLIC_LINK_SECTION_NOT_FOUND",
            "Seção de links não encontrada.",
          );
        }
        const oldSectionId = String(previous.sectionId);
        const oldOrder = Number(previous.sortOrder);
        const maxResult = await transaction.query(
          `SELECT COALESCE(MAX(sort_order), 0)::integer AS max FROM public.public_link_items
           WHERE section_id = $1 AND id <> $2`,
          [input.sectionId, itemId],
        );
        const max = Number(maxResult.rows[0]?.max ?? 0);
        const sortOrder = Math.min(input.sortOrder, max + 1);

        if (oldSectionId === input.sectionId) {
          if (sortOrder < oldOrder) {
            await transaction.query(
              `UPDATE public.public_link_items SET sort_order = sort_order + 1
               WHERE section_id = $1 AND id <> $2 AND sort_order >= $3 AND sort_order < $4`,
              [input.sectionId, itemId, sortOrder, oldOrder],
            );
          } else if (sortOrder > oldOrder) {
            await transaction.query(
              `UPDATE public.public_link_items SET sort_order = sort_order - 1
               WHERE section_id = $1 AND id <> $2 AND sort_order <= $3 AND sort_order > $4`,
              [input.sectionId, itemId, sortOrder, oldOrder],
            );
          }
        } else {
          await transaction.query(
            "UPDATE public.public_link_items SET sort_order = sort_order - 1 WHERE section_id = $1 AND sort_order > $2",
            [oldSectionId, oldOrder],
          );
          await transaction.query(
            "UPDATE public.public_link_items SET sort_order = sort_order + 1 WHERE section_id = $1 AND sort_order >= $2",
            [input.sectionId, sortOrder],
          );
        }

        await transaction.query(
          `UPDATE public.public_link_items SET section_id = $2, display_name = $3, url = $4,
             sort_order = $5, is_active = $6, filter_mode = $7::public.public_link_filter_mode,
             updated_at = now() WHERE id = $1`,
          [
            itemId,
            input.sectionId,
            input.displayName,
            input.url,
            sortOrder,
            input.isActive,
            input.filterMode,
          ],
        );
        await persistFilters(transaction, itemId, input);
        const current = await getItem(transaction, itemId);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "UPDATE",
          "public.public_link_items",
          itemId,
          "Atualizou um link público",
          previous,
          current,
        );
        return current;
      });
      response.status(200).json({ data: item });
    } catch (error) {
      next(error);
    }
  });

  router.delete("/link-items/:itemId", ...requireLinksEdit, async (request, response, next) => {
    try {
      const itemId = requireUuid(request.params.itemId, "itemId");
      await database.transaction(async (transaction) => {
        const previous = await getItem(transaction, itemId);
        if (!previous)
          throw new ApiError(404, "PUBLIC_LINK_ITEM_NOT_FOUND", "Link público não encontrado.");
        await transaction.query("DELETE FROM public.public_link_items WHERE id = $1", [itemId]);
        await transaction.query(
          "UPDATE public.public_link_items SET sort_order = sort_order - 1 WHERE section_id = $1 AND sort_order > $2",
          [previous.sectionId, previous.sortOrder],
        );
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "DELETE",
          "public.public_link_items",
          itemId,
          "Excluiu um link público",
          previous,
          null,
        );
      });
      response.status(204).end();
    } catch (error) {
      next(error);
    }
  });

  return router;
}
