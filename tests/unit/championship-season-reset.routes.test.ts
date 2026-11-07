import assert from "node:assert/strict";
import test from "node:test";

import type { Request, RequestHandler, Response } from "express";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.DATABASE_URL = "postgresql://laje:laje@localhost:5432/laje";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "false";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const [{ database }, { createChampionshipsRouter }] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/modules/championships/championships.routes.js"),
]);

import type { DatabaseQueryExecutor, DatabaseRow } from "../../src/database/types.js";
import type { AuthService } from "../../src/modules/auth/auth.service.js";

const championshipId = "5edbcb36-0864-4a7c-9e89-e72c27c3455f";
const userId = "a6d2b658-dedc-4fbb-8143-18111cb130fe";

test("reinicia somente a temporada atual e bloqueia transições ou divisões conflitantes", async (t) => {
  let status = "IN_PROGRESS";
  const seasonYear = 2027;
  let movements: DatabaseRow[] = [];
  const queries: Array<{ sql: string; values: readonly unknown[] }> = [];

  const query = async <Row extends DatabaseRow = DatabaseRow>(
    sql: string,
    values: readonly unknown[] = [],
  ) => {
    queries.push({ sql, values });
    if (sql.startsWith("SELECT id, code, name, status")) {
      return {
        rows: [
          {
            id: championshipId,
            code: "CLV",
            name: "Copa Laje de Verão",
            status,
            currentSeasonYear: seasonYear,
            usesDivisions: true,
            defaultLocation: null,
            createdAt: "2026-01-01T00:00:00.000Z",
          },
        ] as unknown as Row[],
        count: 1,
      };
    }
    if (sql.includes("FROM public.championship_season_division_movements")) {
      return { rows: movements as unknown as Row[], count: movements.length };
    }
    if (sql.startsWith("DELETE FROM ")) {
      return { rows: [] as Row[], count: sql.includes("public.matches ") ? 12 : 1 };
    }
    if (sql.startsWith("UPDATE public.championships")) {
      status = "PLANNING";
      return { rows: [] as Row[], count: 1 };
    }
    if (sql.startsWith("UPDATE public.teams")) {
      return { rows: [{ id: values[0] }] as unknown as Row[], count: 1 };
    }
    return { rows: [] as Row[], count: 0 };
  };

  t.mock.method(
    database,
    "transaction",
    async <T>(work: (executor: DatabaseQueryExecutor) => Promise<T>): Promise<T> => work({ query }),
  );

  const principal = {
    userId,
    sessionId: "1998933e-8b57-412a-8f5a-a992cb8c4484",
    user: {
      id: userId,
      name: "João Duarte",
      email: "qa@example.invalid",
      role: "admin" as const,
      profile: null,
      permissions: [{ scope: "settings", level: "EDIT" as const }],
      canAccessAdminPanel: true,
    },
  };
  const authService = {
    authenticateAccessToken: async () => principal,
  } as unknown as AuthService;

  const router = createChampionshipsRouter(authService) as unknown as {
    stack: Array<{
      route?: {
        path: string;
        methods: Record<string, boolean>;
        stack: Array<{ handle: RequestHandler }>;
      };
    }>;
  };
  const invoke = (
    method: string,
    path: string,
    params: Record<string, string>,
    body: Record<string, unknown> = {},
  ) =>
    new Promise<{ statusCode: number; body?: unknown }>((resolve, reject) => {
      const response = {
        statusCode: 200,
        status(code: number) {
          this.statusCode = code;
          return this;
        },
        json(responseBody: unknown) {
          resolve({ statusCode: this.statusCode, body: responseBody });
          return this;
        },
        send() {
          resolve({ statusCode: this.statusCode });
          return this;
        },
      };
      const request = {
        method,
        params,
        body,
        header: (name: string) =>
          name.toLowerCase() === "authorization" ? "Bearer test" : undefined,
      };
      const routeLayer = router.stack.find(
        (layer) => layer.route?.path === path && layer.route.methods[method.toLowerCase()],
      );
      assert.ok(routeLayer?.route);
      const handlers = routeLayer.route.stack;
      const dispatch = (index: number): void => {
        const handler = handlers[index];
        if (!handler) {
          resolve({ statusCode: response.statusCode });
          return;
        }
        try {
          const result = handler.handle(
            request as unknown as Request,
            response as unknown as Response,
            (error?: unknown) => {
              if (error) {
                reject(error);
                return;
              }
              dispatch(index + 1);
            },
          );
          Promise.resolve(result).catch(reject);
        } catch (error) {
          reject(error);
        }
      };
      dispatch(0);
    });
  const deleteCount = () => queries.filter(({ sql }) => sql.startsWith("DELETE FROM ")).length;

  await assert.rejects(
    invoke("PATCH", "/:championshipId", { championshipId }, { status: "PLANNING" }),
    (error: { statusCode: number; code: string }) => {
      assert.equal(error.statusCode, 409);
      assert.equal(error.code, "CHAMPIONSHIP_SEASON_RESET_REQUIRED");
      return true;
    },
  );
  assert.equal(deleteCount(), 0);

  await assert.rejects(
    invoke("POST", "/:championshipId/seasons/:seasonYear/reset-to-planning", {
      championshipId,
      seasonYear: "2026",
    }),
    (error: { statusCode: number; code: string }) => {
      assert.equal(error.statusCode, 409);
      assert.equal(error.code, "CHAMPIONSHIP_SEASON_CONFLICT");
      return true;
    },
  );
  assert.equal(deleteCount(), 0);

  status = "FINISHED";
  await assert.rejects(
    invoke("POST", "/:championshipId/seasons/:seasonYear/reset-to-planning", {
      championshipId,
      seasonYear: "2027",
    }),
    (error: { statusCode: number; code: string }) => {
      assert.equal(error.statusCode, 409);
      assert.equal(error.code, "CHAMPIONSHIP_STATE_CONFLICT");
      return true;
    },
  );
  assert.equal(deleteCount(), 0);

  status = "PLANNING";
  await assert.rejects(
    invoke("POST", "/:championshipId/seasons/:seasonYear/reset-to-planning", {
      championshipId,
      seasonYear: "2027",
    }),
    (error: { statusCode: number; code: string }) => {
      assert.equal(error.statusCode, 409);
      assert.equal(error.code, "CHAMPIONSHIP_STATE_CONFLICT");
      return true;
    },
  );
  assert.equal(deleteCount(), 0);

  status = "IN_PROGRESS";
  movements = [
    {
      teamId: "f2e4d8cc-86f7-4b56-8aa2-7e7957b36030",
      previousDivision: "DIVISAO_PRINCIPAL",
      nextDivision: "DIVISAO_ACESSO",
      currentDivision: "DIVISAO_PRINCIPAL",
    },
  ];
  await assert.rejects(
    invoke("POST", "/:championshipId/seasons/:seasonYear/reset-to-planning", {
      championshipId,
      seasonYear: "2027",
    }),
    (error: { statusCode: number; code: string }) => {
      assert.equal(error.statusCode, 409);
      assert.equal(error.code, "CHAMPIONSHIP_DIVISION_MOVEMENT_CONFLICT");
      return true;
    },
  );
  assert.equal(deleteCount(), 0);

  movements = [
    {
      teamId: "f2e4d8cc-86f7-4b56-8aa2-7e7957b36030",
      previousDivision: "DIVISAO_PRINCIPAL",
      nextDivision: "DIVISAO_ACESSO",
      currentDivision: "DIVISAO_ACESSO",
    },
  ];
  const beforeResetQueryIndex = queries.length;
  const reset = await invoke("POST", "/:championshipId/seasons/:seasonYear/reset-to-planning", {
    championshipId,
    seasonYear: "2027",
  });
  assert.equal(reset.statusCode, 204);
  assert.equal(status, "PLANNING");
  assert.equal(seasonYear, 2027);

  const resetQueries = queries.slice(beforeResetQueryIndex);
  const deleteQueries = resetQueries.filter(({ sql }) => sql.startsWith("DELETE FROM "));
  assert.ok(
    deleteQueries.some(({ sql }) => sql.includes("championship_bracket_preview_private.jobs")),
  );
  assert.ok(deleteQueries.every(({ sql }) => !sql.includes("public.match_award_goalkeepers")));
  assert.ok(
    deleteQueries.some(({ sql }) => sql.includes("public.match_two_minute_penalty_players")),
  );
  assert.ok(deleteQueries.some(({ sql }) => sql.includes("public.matches")));
  const bracketMatchesDeleteIndex = deleteQueries.findIndex(({ sql }) =>
    sql.startsWith("DELETE FROM public.championship_bracket_matches "),
  );
  const matchesDeleteIndex = deleteQueries.findIndex(({ sql }) =>
    sql.startsWith("DELETE FROM public.matches "),
  );
  assert.ok(bracketMatchesDeleteIndex >= 0);
  assert.ok(matchesDeleteIndex >= 0);
  assert.ok(bracketMatchesDeleteIndex < matchesDeleteIndex);
  assert.ok(
    deleteQueries.some(({ sql }) =>
      sql.includes("public.championship_bracket_tie_break_resolution_teams"),
    ),
  );
  assert.ok(
    deleteQueries.some(({ sql }) => sql.includes("public.championship_bracket_day_breaks")),
  );
  assert.ok(
    deleteQueries.some(({ sql }) =>
      sql.includes("public.championship_bracket_location_sport_priorities"),
    ),
  );
  assert.ok(
    deleteQueries.some(({ sql }) =>
      sql.includes("public.championship_bracket_knockout_court_priorities"),
    ),
  );
  assert.ok(
    deleteQueries.every(({ values }) => values[0] === championshipId && values[1] === seasonYear),
  );
  assert.ok(
    deleteQueries.every(
      ({ sql }) =>
        !/DELETE FROM (?:public\.)?(?:championships|teams|sports|admin_action_logs)\b/.test(sql),
    ),
  );
  assert.ok(
    resetQueries.some(
      ({ sql, values }) =>
        sql.startsWith("UPDATE public.teams") &&
        values[1] === "DIVISAO_PRINCIPAL" &&
        values[2] === "DIVISAO_ACESSO",
    ),
  );
  const audit = resetQueries.find(({ sql }) =>
    sql.startsWith("INSERT INTO public.admin_action_logs"),
  );
  assert.ok(audit);
  assert.deepEqual(audit.values[7], { seasonYear: 2027, status: "IN_PROGRESS" });
  const auditNewData = audit.values[8] as Record<string, unknown>;
  assert.equal(auditNewData.seasonYear, 2027);
  assert.equal(auditNewData.status, "PLANNING");
  assert.equal(auditNewData.restoredTeamDivisionCount, 1);
  assert.deepEqual(
    auditNewData.deletedCounts,
    Object.fromEntries(
      deleteQueries.map(({ sql }) => [
        sql
          .match(/DELETE FROM (.+?) WHERE/)?.[1]
          ?.split(".")
          .at(-1),
        sql.includes("public.matches ") ? 12 : 1,
      ]),
    ),
  );
  const transitionGuard = resetQueries.find(({ sql }) =>
    sql.includes("allow_championship_planning_transition"),
  );
  assert.ok(transitionGuard);

  for (const previousStatus of ["UPCOMING", "REVIEW"]) {
    status = previousStatus;
    movements = [];
    const statusReset = await invoke(
      "POST",
      "/:championshipId/seasons/:seasonYear/reset-to-planning",
      { championshipId, seasonYear: "2027" },
    );
    assert.equal(statusReset.statusCode, 204);
    assert.equal(status, "PLANNING");
    const statusResetAudit = queries
      .slice(beforeResetQueryIndex)
      .findLast(
        ({ sql, values }) =>
          sql.startsWith("INSERT INTO public.admin_action_logs") &&
          (values[7] as Record<string, unknown>).status === previousStatus,
      );
    assert.ok(statusResetAudit);
  }
});
