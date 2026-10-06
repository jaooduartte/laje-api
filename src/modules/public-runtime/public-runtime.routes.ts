import { Router } from "express";

import {
  optionalEnum,
  optionalInteger,
  optionalUuid,
  requireInteger,
  requireUuid,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";

const CHAMPIONSHIP_CODES = ["CLV", "SOCIETY", "INTERLAJE"] as const;
const MATCH_NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const TEAM_DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;
const INDIVIDUAL_SESSION_STATUSES = ["DRAFT", "SCHEDULED", "LIVE", "FINISHED"] as const;

function queryValues(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.flatMap((entry) => (typeof entry === "string" ? [entry] : []));
  }

  return typeof value === "string" ? [value] : [];
}

async function loadHomeDashboardMetrics(
  seasonYear: number | undefined,
  championshipCode: (typeof CHAMPIONSHIP_CODES)[number] | undefined,
) {
  const resolvedSeasonResult = await database.query(
    "SELECT COALESCE($1::integer, MAX(current_season_year))::integer AS season_year FROM public.championships",
    [seasonYear ?? null],
  );
  const resolvedSeasonYear = Number(resolvedSeasonResult.rows[0]?.season_year ?? new Date().getFullYear());

  const championshipFilter = championshipCode
    ? "AND c.code = $1::public.championship_code"
    : "";
  const championshipParameters = championshipCode ? [championshipCode] : [];

  const selectedChampionships = await database.query(
    `SELECT c.id, c.code FROM public.championships c WHERE true ${championshipFilter}`,
    championshipParameters,
  );
  const championshipIds = selectedChampionships.rows.map((row) => String(row.id));

  if (championshipIds.length === 0) {
    return {
      season_year: resolvedSeasonYear,
      top_performance: [],
      most_matches: [],
      most_appearances: [],
      season_highlights: [],
      championship_dominance: [],
      modality_participation: [],
      season_insights: [],
      next_event_day: null,
      next_events: [],
    };
  }

  const topPerformanceResult = await database.query(
    `WITH adjustments AS (
       SELECT team_id, SUM(points)::numeric AS points
       FROM public.championship_overall_score_adjustments
       WHERE championship_id = ANY($1::uuid[])
       GROUP BY team_id
     )
     SELECT s.team_id, t.name AS team_name,
       (SUM(s.points)::numeric + COALESCE(MAX(a.points), 0))::float8 AS value,
       SUM(s.wins)::int AS secondary_value
     FROM public.standings s
     JOIN public.teams t ON t.id = s.team_id
     LEFT JOIN adjustments a ON a.team_id = s.team_id
     WHERE s.championship_id = ANY($1::uuid[])
     GROUP BY s.team_id, t.name
     ORDER BY value DESC, secondary_value DESC, t.name ASC
     LIMIT 5`,
    [championshipIds],
  );

  const mostMatchesResult = await database.query(
    `WITH team_matches AS (
       SELECT home_team_id AS team_id, COUNT(*)::int AS matches_count,
         COUNT(*) FILTER (WHERE status = 'FINISHED'::public.match_status)::int AS finished_count
       FROM public.matches WHERE championship_id = ANY($1::uuid[]) GROUP BY home_team_id
       UNION ALL
       SELECT away_team_id AS team_id, COUNT(*)::int AS matches_count,
         COUNT(*) FILTER (WHERE status = 'FINISHED'::public.match_status)::int AS finished_count
       FROM public.matches WHERE championship_id = ANY($1::uuid[]) GROUP BY away_team_id
     )
     SELECT tm.team_id, t.name AS team_name, SUM(tm.matches_count)::int AS value,
       SUM(tm.finished_count)::int AS secondary_value
     FROM team_matches tm JOIN public.teams t ON t.id = tm.team_id
     GROUP BY tm.team_id, t.name
     ORDER BY value DESC, secondary_value DESC, t.name ASC LIMIT 5`,
    [championshipIds],
  );

  const mostAppearancesResult = await database.query(
    `SELECT s.team_id, t.name AS team_name, COUNT(DISTINCT s.season_year)::int AS value,
       COUNT(*)::int AS secondary_value
     FROM public.standings s JOIN public.teams t ON t.id = s.team_id
     WHERE s.championship_id = ANY($1::uuid[])
     GROUP BY s.team_id, t.name
     ORDER BY value DESC, secondary_value DESC, t.name ASC LIMIT 5`,
    [championshipIds],
  );

  const seasonHighlightsResult = await database.query(
    `WITH adjustments AS (
       SELECT team_id, SUM(points)::numeric AS points
       FROM public.championship_overall_score_adjustments
       WHERE championship_id = ANY($1::uuid[]) AND season_year = $2
       GROUP BY team_id
     )
     SELECT s.team_id, t.name AS team_name,
       (SUM(s.points)::numeric + COALESCE(MAX(a.points), 0))::float8 AS value,
       SUM(s.wins)::int AS secondary_value
     FROM public.standings s
     JOIN public.teams t ON t.id = s.team_id
     LEFT JOIN adjustments a ON a.team_id = s.team_id
     WHERE s.championship_id = ANY($1::uuid[]) AND s.season_year = $2
     GROUP BY s.team_id, t.name
     ORDER BY value DESC, secondary_value DESC, t.name ASC LIMIT 5`,
    [championshipIds, resolvedSeasonYear],
  );

  const dominanceResult = await database.query(
    `WITH totals AS (
       SELECT c.code AS championship_code, s.team_id, t.name AS team_name,
         SUM(s.points)::float8 AS titles_count,
         ROW_NUMBER() OVER (
           PARTITION BY c.code ORDER BY SUM(s.points) DESC, t.name ASC
         ) AS position
       FROM public.standings s
       JOIN public.championships c ON c.id = s.championship_id
       JOIN public.teams t ON t.id = s.team_id
       WHERE s.championship_id = ANY($1::uuid[])
       GROUP BY c.code, s.team_id, t.name
     )
     SELECT championship_code, team_id, team_name, titles_count
     FROM totals WHERE position = 1
     ORDER BY CASE championship_code WHEN 'CLV' THEN 1 WHEN 'SOCIETY' THEN 2 WHEN 'INTERLAJE' THEN 3 ELSE 99 END`,
    [championshipIds],
  );

  const modalityResult = await database.query(
    `SELECT s.team_id, t.name AS team_name,
       COUNT(DISTINCT (s.sport_id::text || '-' || s.naipe::text || '-' || COALESCE(s.division::text, 'ND')))::int AS value,
       COUNT(DISTINCT s.championship_id)::int AS secondary_value
     FROM public.standings s JOIN public.teams t ON t.id = s.team_id
     WHERE s.championship_id = ANY($1::uuid[]) AND s.season_year = $2
     GROUP BY s.team_id, t.name
     ORDER BY value DESC, secondary_value DESC, t.name ASC LIMIT 5`,
    [championshipIds, resolvedSeasonYear],
  );

  const mostWinsResult = await database.query(
    `SELECT s.team_id, t.name AS team_name, SUM(s.wins)::int AS value
     FROM public.standings s JOIN public.teams t ON t.id = s.team_id
     WHERE s.championship_id = ANY($1::uuid[])
     GROUP BY s.team_id, t.name ORDER BY value DESC, t.name ASC LIMIT 1`,
    [championshipIds],
  );

  const biggestWinResult = await database.query(
    `SELECT
       CASE WHEN m.home_score > m.away_score THEN ht.name ELSE at.name END AS team_name,
       ABS(m.home_score - m.away_score)::int AS value,
       m.season_year, c.code AS championship_code, s.name AS sport_name, m.naipe,
       CASE
         WHEN COALESCE(s.code, '') IN ('BEACH_SOCCER','FUTEBOL_SOCIETY','FUTSAL','HANDEBOL')
           OR s.name ILIKE '%futebol%' OR s.name ILIKE '%futsal%' OR s.name ILIKE '%handebol%'
         THEN 'gols'
         ELSE 'pontos'
       END AS unit
     FROM public.matches m
     JOIN public.championships c ON c.id = m.championship_id
     JOIN public.sports s ON s.id = m.sport_id
     JOIN public.teams ht ON ht.id = m.home_team_id
     JOIN public.teams at ON at.id = m.away_team_id
     WHERE m.championship_id = ANY($1::uuid[])
       AND m.status = 'FINISHED'::public.match_status
       AND m.home_score <> m.away_score
     ORDER BY ABS(m.home_score - m.away_score) DESC, m.season_year DESC
     LIMIT 1`,
    [championshipIds],
  );

  const podiumResult = await database.query(
    `WITH ranked AS (
       SELECT s.*, ROW_NUMBER() OVER (
         PARTITION BY s.championship_id, s.season_year, s.sport_id, s.naipe, s.division
         ORDER BY s.points DESC, s.wins DESC, s.goal_diff DESC, s.goals_for DESC, s.team_id
       ) AS placement
       FROM public.standings s WHERE s.championship_id = ANY($1::uuid[])
     )
     SELECT r.team_id, t.name AS team_name,
       COUNT(*) FILTER (WHERE r.placement <= 3)::int AS value
     FROM ranked r JOIN public.teams t ON t.id = r.team_id
     GROUP BY r.team_id, t.name ORDER BY value DESC, t.name ASC LIMIT 1`,
    [championshipIds],
  );

  const nextEventsResult = await database.query(
    `SELECT le.event_date::text AS event_date, le.name, le.event_type,
       CASE WHEN le.organizer_type = 'LAJE'::public.league_event_organizer_type
         THEN 'LAJE' ELSE COALESCE(t.name, 'Atlética') END AS organizer_name
     FROM public.league_events le
     LEFT JOIN public.teams t ON t.id = le.organizer_team_id
     WHERE le.event_date >= CURRENT_DATE
     ORDER BY le.event_date ASC, le.name ASC LIMIT 3`,
  );

  const nextEventDayResult = await database.query(
    `WITH next_day AS (
       SELECT MIN(event_date) AS event_date FROM public.league_events WHERE event_date >= CURRENT_DATE
     )
     SELECT le.event_date::text AS event_date, le.name, le.event_type,
       CASE WHEN le.organizer_type = 'LAJE'::public.league_event_organizer_type
         THEN 'LAJE' ELSE COALESCE(t.name, 'Atlética') END AS organizer_name
     FROM public.league_events le
     LEFT JOIN public.teams t ON t.id = le.organizer_team_id
     WHERE le.event_date = (SELECT event_date FROM next_day)
     ORDER BY le.name ASC`,
  );

  const seasonInsights = [
    mostWinsResult.rows[0]
      ? {
          id: "MOST_WINS",
          label: "Mais vitórias no histórico",
          team_name: mostWinsResult.rows[0].team_name,
          value: Number(mostWinsResult.rows[0].value),
          unit: "vitórias",
        }
      : null,
    topPerformanceResult.rows[0]
      ? {
          id: "MOST_POINTS",
          label: "Mais pontos no histórico",
          team_name: topPerformanceResult.rows[0].team_name,
          value: Number(topPerformanceResult.rows[0].value),
          unit: "pontos",
        }
      : null,
    biggestWinResult.rows[0]
      ? {
          id: "BIGGEST_WIN_MARGIN",
          label: "Maior diferença em vitória",
          team_name: biggestWinResult.rows[0].team_name,
          value: Number(biggestWinResult.rows[0].value),
          unit: biggestWinResult.rows[0].unit,
          season_year: Number(biggestWinResult.rows[0].season_year),
          championship_code: biggestWinResult.rows[0].championship_code,
          sport_name: biggestWinResult.rows[0].sport_name,
        }
      : null,
    podiumResult.rows[0]
      ? {
          id: "MOST_PODIUMS",
          label: "Mais pódios no histórico",
          team_name: podiumResult.rows[0].team_name,
          value: Number(podiumResult.rows[0].value),
          unit: "pódios",
        }
      : null,
  ].filter(Boolean);

  const nextEventRows = nextEventDayResult.rows;
  return {
    season_year: resolvedSeasonYear,
    top_performance: topPerformanceResult.rows.map((row) => ({
      ...row,
      value: Number(row.value),
      secondary_value: Number(row.secondary_value),
    })),
    most_matches: mostMatchesResult.rows,
    most_appearances: mostAppearancesResult.rows,
    season_highlights: seasonHighlightsResult.rows.map((row) => ({
      ...row,
      value: Number(row.value),
      secondary_value: Number(row.secondary_value),
    })),
    championship_dominance: dominanceResult.rows.map((row) => ({
      ...row,
      titles_count: Number(row.titles_count),
    })),
    modality_participation: modalityResult.rows,
    season_insights: seasonInsights,
    next_event_day:
      nextEventRows.length > 0
        ? {
            event_date: nextEventRows[0]!.event_date,
            events: nextEventRows.map((row) => ({
              name: row.name,
              event_type: row.event_type,
              organizer_name: row.organizer_name,
            })),
          }
        : null,
    next_events: nextEventsResult.rows,
  };
}

export function createPublicRuntimeRouter(): Router {
  const router = Router();

  router.get("/teams", async (request, response, next) => {
    try {
      const includeInactive = request.query.includeInactive === "true";
      const result = await database.query(
        `SELECT id, name, city, division, is_active AS "isActive", created_at::text AS "createdAt"
         FROM public.teams
         ${includeInactive ? "" : "WHERE is_active = true"}
         ORDER BY name ASC`,
      );
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.get("/sports", async (request, response, next) => {
    try {
      const championshipId = optionalUuid(request.query.championshipId, "championshipId");
      if (!championshipId) {
        const sports = await database.query(
          `SELECT id, name, code, default_match_duration_minutes AS "defaultMatchDurationMinutes",
             created_at::text AS "createdAt"
           FROM public.sports ORDER BY name ASC`,
        );
        response.status(200).json({ data: { sports: sports.rows, championshipSports: [] } });
        return;
      }

      const result = await database.query(
        `SELECT
           cs.id, cs.championship_id AS "championshipId", cs.sport_id AS "sportId",
           cs.naipe_mode AS "naipeMode", cs.result_rule AS "resultRule",
           cs.supports_cards AS "supportsCards", cs.tie_breaker_rule AS "tieBreakerRule",
           cs.default_match_duration_minutes AS "defaultMatchDurationMinutes",
           cs.show_estimated_start_time_on_cards AS "showEstimatedStartTimeOnCards",
           cs.points_win AS "pointsWin", cs.points_draw AS "pointsDraw", cs.points_loss AS "pointsLoss",
           cs.walkover_winner_points AS "walkoverWinnerPoints",
           cs.walkover_winner_set_count AS "walkoverWinnerSetCount",
           cs.awards_include_knockout_phase AS "awardsIncludeKnockoutPhase",
           cs.supports_individual_awards AS "supportsIndividualAwards",
           cs.classification_policy AS "classificationPolicy",
           cs.created_at::text AS "createdAt",
           s.id AS "sportIdValue", s.name AS "sportName", s.code AS "sportCode",
           s.default_match_duration_minutes AS "sportDefaultMatchDurationMinutes",
           s.created_at::text AS "sportCreatedAt"
         FROM public.championship_sports cs
         JOIN public.sports s ON s.id = cs.sport_id
         WHERE cs.championship_id = $1
         ORDER BY cs.created_at ASC, s.name ASC`,
        [championshipId],
      );

      response.status(200).json({
        data: {
          sports: result.rows.map((row) => ({
            id: row.sportIdValue,
            name: row.sportName,
            code: row.sportCode,
            defaultMatchDurationMinutes: row.sportDefaultMatchDurationMinutes,
            createdAt: row.sportCreatedAt,
          })),
          championshipSports: result.rows.map((row) => ({
            id: row.id,
            championshipId: row.championshipId,
            sportId: row.sportId,
            naipeMode: row.naipeMode,
            resultRule: row.resultRule,
            supportsCards: row.supportsCards,
            tieBreakerRule: row.tieBreakerRule,
            defaultMatchDurationMinutes: row.defaultMatchDurationMinutes,
            showEstimatedStartTimeOnCards: row.showEstimatedStartTimeOnCards,
            pointsWin: row.pointsWin,
            pointsDraw: row.pointsDraw,
            pointsLoss: row.pointsLoss,
            walkoverWinnerPoints: row.walkoverWinnerPoints,
            walkoverWinnerSetCount: row.walkoverWinnerSetCount,
            awardsIncludeKnockoutPhase: row.awardsIncludeKnockoutPhase,
            supportsIndividualAwards: row.supportsIndividualAwards,
            classificationPolicy: row.classificationPolicy,
            createdAt: row.createdAt,
          })),
        },
      });
    } catch (error) {
      next(error);
    }
  });

  router.get("/championships/:championshipId/individual-events", async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      const sportId = optionalUuid(request.query.sportId, "sportId");
      const params: unknown[] = [championshipId, seasonYear];
      const sportFilter = sportId ? ` AND e.sport_id = $${params.push(sportId)}` : "";
      const result = await database.query(
        `SELECT e.*, s.id AS "sport_join_id", s.name AS "sport_join_name",
           s.code AS "sport_join_code", s.created_at::text AS "sport_join_created_at"
         FROM public.championship_individual_events e
         JOIN public.sports s ON s.id = e.sport_id
         WHERE e.championship_id = $1 AND e.season_year = $2${sportFilter}
         ORDER BY e.scheduled_date ASC NULLS LAST, e.display_order ASC, e.created_at ASC`,
        params,
      );
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.get("/championships/:championshipId/individual-sessions", async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      const sportId = optionalUuid(request.query.sportId, "sportId");
      const status = optionalEnum(request.query.status, "status", INDIVIDUAL_SESSION_STATUSES);
      const params: unknown[] = [championshipId, seasonYear];
      const filters: string[] = [];
      if (sportId) filters.push(`sesh.sport_id = $${params.push(sportId)}`);
      if (status) filters.push(`sesh.status = $${params.push(status)}::public.championship_individual_session_status`);
      const extraWhere = filters.length ? ` AND ${filters.join(" AND ")}` : "";
      const result = await database.query(
        `SELECT sesh.*, s.id AS "sport_join_id", s.name AS "sport_join_name",
           s.code AS "sport_join_code", s.created_at::text AS "sport_join_created_at"
         FROM public.championship_individual_sessions sesh
         JOIN public.sports s ON s.id = sesh.sport_id
         WHERE sesh.championship_id = $1 AND sesh.season_year = $2${extraWhere}
         ORDER BY sesh.scheduled_date ASC NULLS LAST, sesh.created_at ASC`,
        params,
      );
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.get("/individual-event-entries", async (request, response, next) => {
    try {
      const eventIds = queryValues(request.query.eventId).map((value) => requireUuid(value, "eventId"));
      if (eventIds.length === 0) {
        response.status(200).json({ data: [], membersByEntryId: {} });
        return;
      }
      const entries = await database.query(
        `SELECT e.*, t.id AS "team_join_id", t.name AS "team_join_name",
           t.city AS "team_join_city", t.division AS "team_join_division",
           t.created_at::text AS "team_join_created_at"
         FROM public.championship_individual_event_entries e
         JOIN public.teams t ON t.id = e.team_id
         WHERE e.event_id = ANY($1::uuid[]) ORDER BY e.created_at ASC`,
        [eventIds],
      );
      const entryIds = entries.rows.map((row) => String(row.id));
      const members = entryIds.length
        ? await database.query(
            `SELECT * FROM public.championship_individual_event_entry_members
             WHERE entry_id = ANY($1::uuid[]) ORDER BY entry_id, position ASC`,
            [entryIds],
          )
        : { rows: [] };
      const membersByEntryId: Record<string, unknown[]> = {};
      for (const member of members.rows) {
        const key = String(member.entry_id);
        membersByEntryId[key] = [...(membersByEntryId[key] ?? []), member];
      }
      response.status(200).json({ data: entries.rows, membersByEntryId });
    } catch (error) {
      next(error);
    }
  });

  router.get("/championships/:championshipId/individual-standings", async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      const sportId = optionalUuid(request.query.sportId, "sportId");
      const naipe = optionalEnum(request.query.naipe, "naipe", MATCH_NAIPES);
      const division = optionalEnum(request.query.division, "division", TEAM_DIVISIONS);
      const params: unknown[] = [championshipId, seasonYear];
      const filters: string[] = [];
      if (sportId) filters.push(`st.sport_id = $${params.push(sportId)}`);
      if (naipe) filters.push(`st.naipe = $${params.push(naipe)}::public.match_naipe`);
      if (division) filters.push(`st.division = $${params.push(division)}::public.team_division`);
      const extraWhere = filters.length ? ` AND ${filters.join(" AND ")}` : "";
      const result = await database.query(
        `SELECT st.*,
           t.id AS "team_join_id", t.name AS "team_join_name", t.city AS "team_join_city",
           t.division AS "team_join_division", t.created_at::text AS "team_join_created_at",
           s.id AS "sport_join_id", s.name AS "sport_join_name", s.code AS "sport_join_code",
           s.created_at::text AS "sport_join_created_at"
         FROM public.championship_individual_team_standings st
         JOIN public.teams t ON t.id = st.team_id
         JOIN public.sports s ON s.id = st.sport_id
         WHERE st.championship_id = $1 AND st.season_year = $2${extraWhere}
         ORDER BY st.total_points DESC, st.first_places DESC, st.second_places DESC, st.third_places DESC`,
        params,
      );
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.get("/home-dashboard", async (request, response, next) => {
    try {
      const seasonYear = optionalInteger(request.query.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      const championshipCode = optionalEnum(request.query.championshipCode, "championshipCode", CHAMPIONSHIP_CODES);
      response.status(200).json({ data: await loadHomeDashboardMetrics(seasonYear, championshipCode) });
    } catch (error) {
      next(error);
    }
  });

  return router;
}
