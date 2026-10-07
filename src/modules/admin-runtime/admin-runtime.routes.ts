import { Router } from "express";

import {
  optionalEnum,
  optionalString,
  optionalUuid,
  parsePagination,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import {
  createRequireAuthentication,
  requirePermission,
} from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";

const ADMIN_ACTION_TYPES = [
  "INSERT",
  "UPDATE",
  "DELETE",
  "PASSWORD_CHANGED",
  "LOGIN",
] as const;

export function createAdminRuntimeRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireUsersView = [
    requireAuthentication,
    requirePermission("users", "VIEW"),
  ] as const;
  const requireLogsView = [
    requireAuthentication,
    requirePermission("logs", "VIEW"),
  ] as const;

  router.get("/users", ...requireUsersView, async (_request, response, next) => {
    try {
      const [usersResult, profilesResult] = await Promise.all([
        database.query(
          `SELECT
             aup.user_id AS "userId",
             aup.name,
             aaa.email,
             aup.login_identifier AS "loginIdentifier",
             aup.password_status AS "passwordStatus",
             ap.system_role AS role,
             aup.profile_id AS "profileId",
             ap.name AS "profileName",
             aup.created_at::text AS "createdAt",
             (
               SELECT max(log.created_at)::text
               FROM public.admin_action_logs log
               WHERE log.actor_user_id = aup.user_id
             ) AS "lastSignInAt"
           FROM public.admin_user_profiles aup
           JOIN public.admin_profiles ap ON ap.id = aup.profile_id
           LEFT JOIN public.admin_auth_accounts aaa ON aaa.user_id = aup.user_id
           ORDER BY aup.name ASC, aup.login_identifier ASC`,
        ),
        database.query(
          `SELECT
             ap.id AS "profileId",
             ap.name AS "profileName",
             ap.is_system AS "isSystem",
             jsonb_object_agg(
               tabs.admin_tab::text,
               COALESCE(app.access_level::text, 'NONE')
             ) AS permissions,
             ap.created_at::text AS "createdAt",
             ap.updated_at::text AS "updatedAt"
           FROM public.admin_profiles ap
           CROSS JOIN unnest(enum_range(NULL::public.admin_panel_tab))
             AS tabs(admin_tab)
           LEFT JOIN public.admin_profile_permissions app
             ON app.profile_id = ap.id
            AND app.admin_tab = tabs.admin_tab
           GROUP BY ap.id
           ORDER BY ap.is_system DESC, ap.name ASC`,
        ),
      ]);

      response.status(200).json({
        data: {
          users: usersResult.rows,
          profiles: profilesResult.rows,
        },
      });
    } catch (error) {
      next(error);
    }
  });

  router.get("/logs", ...requireLogsView, async (request, response, next) => {
    try {
      const { page, pageSize, offset } = parsePagination(
        request.query as Record<string, unknown>,
      );
      const userId = optionalUuid(request.query.userId, "userId");
      const actionType = optionalEnum(
        request.query.actionType,
        "actionType",
        ADMIN_ACTION_TYPES,
      );
      const search = optionalString(request.query.search, "search", 200);

      const parameters: unknown[] = [];
      const conditions = [
        "resource_table <> 'league_event_organizer_teams'",
      ];

      if (userId) {
        parameters.push(userId);
        conditions.push(`actor_user_id = $${parameters.length}::uuid`);
      }

      if (actionType) {
        parameters.push(actionType);
        conditions.push(
          `action_type = $${parameters.length}::public.admin_action_type`,
        );
      }

      if (search) {
        parameters.push(`%${search}%`);
        const parameter = `$${parameters.length}`;
        conditions.push(
          `(
            resource_table ILIKE ${parameter}
            OR COALESCE(description, '') ILIKE ${parameter}
            OR COALESCE(actor_name, '') ILIKE ${parameter}
            OR COALESCE(actor_email, '') ILIKE ${parameter}
            OR COALESCE(record_id, '') ILIKE ${parameter}
          )`,
        );
      }

      parameters.push(pageSize, offset);
      const limitParameter = `$${parameters.length - 1}`;
      const offsetParameter = `$${parameters.length}`;

      const result = await database.query(
        `SELECT
           id,
           actor_user_id AS "actorUserId",
           actor_name AS "actorName",
           actor_email AS "actorEmail",
           actor_role AS "actorRole",
           action_type AS "actionType",
           resource_table AS "resourceTable",
           record_id AS "recordId",
           description,
           old_data AS "oldData",
           new_data AS "newData",
           metadata,
           created_at::text AS "createdAt",
           count(*) OVER()::int AS "totalCount"
         FROM public.admin_action_logs
         WHERE ${conditions.join(" AND ")}
         ORDER BY created_at DESC
         LIMIT ${limitParameter}
         OFFSET ${offsetParameter}`,
        parameters,
      );

      response.status(200).json({
        data: {
          page,
          pageSize,
          totalCount: Number(result.rows[0]?.totalCount ?? 0),
          logs: result.rows.map(({ totalCount: _totalCount, ...row }) => row),
        },
      });
    } catch (error) {
      next(error);
    }
  });

  return router;
}
