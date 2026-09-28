import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalEnum,
  optionalUuid,
  parsePagination,
  requireInteger,
  requireUuid,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import {
  rankStandings,
  resolveTieBreakCascade,
  type FinishedMatchForTieBreak,
  type StandingRankingRow,
} from "./standings.service.js";

const MATCH_NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const TEAM_DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;

interface StandingRow extends StandingRankingRow {
  id: string;
  championshipId: string;
  seasonYear: number;
  sportId: string;
  sportName: string;
  sportCode: string | null;
  naipe: string;
  division: string | null;
  teamCity: string;
  played: number;
  draws: number;
  losses: number;
  legacyRule: string | null;
  classificationPolicy: unknown;
  source: "COLLECTIVE";
}

interface IndividualStandingRow {
  id: string;
  championshipId: string;
  seasonYear: number;
  sportId: string;
  sportName: string;
  sportCode: string | null;
  naipe: string;
  division: string | null;
  teamId: string;
  teamName: string;
  teamCity: string;
  totalPoints: number;
  scoredEventsCount: number;
  firstPlaces: number;
  secondPlaces: number;
  thirdPlaces: number;
  relayPointsTotal: number;
  source: "INDIVIDUAL";
}

function groupKey(row: Pick<StandingRow, "sportId" | "naipe" | "division">): string {
  return `${row.sportId}:${row.naipe}:${row.division ?? "WITHOUT_DIVISION"}`;
}

function toNumber(value: unknown): number {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeStanding(row: Record<string, unknown>): StandingRow {
  return {
    id: String(row.id),
    championshipId: String(row.championshipId),
    seasonYear: toNumber(row.seasonYear),
    sportId: String(row.sportId),
    sportName: String(row.sportName),
    sportCode: typeof row.sportCode == "string" ? row.sportCode : null,
    naipe: String(row.naipe),
    division: typeof row.division == "string" ? row.division : null,
    teamId: String(row.teamId),
    teamName: String(row.teamName),
    teamCity: String(row.teamCity ?? ""),
    played: toNumber(row.played),
    wins: toNumber(row.wins),
    draws: toNumber(row.draws),
    losses: toNumber(row.losses),
    goalsFor: toNumber(row.goalsFor),
    goalsAgainst: toNumber(row.goalsAgainst),
    goalDiff: toNumber(row.goalDiff),
    points: toNumber(row.points),
    yellowCards: toNumber(row.yellowCards),
    redCards: toNumber(row.redCards),
    blueCards: toNumber(row.blueCards),
    twoMinutePenalties: toNumber(row.twoMinutePenalties),
    setsFor: toNumber(row.setsFor),
    setsAgainst: toNumber(row.setsAgainst),
    rallyPointsFor: toNumber(row.rallyPointsFor),
    rallyPointsAgainst: toNumber(row.rallyPointsAgainst),
    legacyRule: typeof row.legacyRule == "string" ? row.legacyRule : null,
    classificationPolicy: row.classificationPolicy,
    source: "COLLECTIVE",
  };
}

export function createStandingsRouter(): Router {
  const router = Router({ mergeParams: true });

  router.get("/", async (request, response, next) => {
    try {
      const inheritedParams = request.params as Record<string, unknown>;
      const championshipId = requireUuid(inheritedParams.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", {
        min: 2000,
        max: 2100,
      });
      const sportId = optionalUuid(request.query.sportId, "sportId");
      const naipe = optionalEnum(request.query.naipe, "naipe", MATCH_NAIPES);
      const division = optionalEnum(request.query.division, "division", TEAM_DIVISIONS);
      const { page, pageSize, offset } = parsePagination(request.query as Record<string, unknown>);

      const championship = await database.query(
        "SELECT id FROM public.championships WHERE id = $1",
        [championshipId],
      );
      if (championship.rows.length === 0) {
        throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
      }

      const parameters: unknown[] = [championshipId, seasonYear];
      const conditions = ["st.championship_id = $1", "st.season_year = $2"];
      if (sportId) {
        parameters.push(sportId);
        conditions.push(`st.sport_id = $${parameters.length}`);
      }
      if (naipe) {
        parameters.push(naipe);
        conditions.push(`st.naipe = $${parameters.length}::public.match_naipe`);
      }
      if (division) {
        parameters.push(division);
        conditions.push(`st.division = $${parameters.length}::public.team_division`);
      }

      const collectiveResult = await database.query(
        `SELECT
          st.id,
          st.championship_id AS "championshipId",
          st.season_year AS "seasonYear",
          st.sport_id AS "sportId",
          sp.name AS "sportName",
          sp.code AS "sportCode",
          st.naipe,
          st.division,
          st.team_id AS "teamId",
          t.name AS "teamName",
          t.city AS "teamCity",
          st.played, st.wins, st.draws, st.losses,
          st.goals_for AS "goalsFor", st.goals_against AS "goalsAgainst",
          st.goal_diff AS "goalDiff", st.points,
          st.yellow_cards AS "yellowCards", st.red_cards AS "redCards",
          st.blue_cards AS "blueCards", st.two_minute_penalties AS "twoMinutePenalties",
          st.sets_for AS "setsFor", st.sets_against AS "setsAgainst",
          st.rally_points_for AS "rallyPointsFor", st.rally_points_against AS "rallyPointsAgainst",
          cs.tie_breaker_rule AS "legacyRule", cs.classification_policy AS "classificationPolicy"
        FROM public.standings st
        JOIN public.teams t ON t.id = st.team_id
        JOIN public.sports sp ON sp.id = st.sport_id
        LEFT JOIN public.championship_sports cs
          ON cs.championship_id = st.championship_id AND cs.sport_id = st.sport_id
        WHERE ${conditions.join(" AND ")}
        ORDER BY sp.name, st.naipe, st.division NULLS FIRST, t.name`,
        parameters,
      );

      const matchParameters: unknown[] = [championshipId, seasonYear];
      const matchConditions = [
        "m.championship_id = $1",
        "m.season_year = $2",
        "m.status = 'FINISHED'",
      ];
      if (sportId) {
        matchParameters.push(sportId);
        matchConditions.push(`m.sport_id = $${matchParameters.length}`);
      }
      if (naipe) {
        matchParameters.push(naipe);
        matchConditions.push(`m.naipe = $${matchParameters.length}::public.match_naipe`);
      }
      if (division) {
        matchParameters.push(division);
        matchConditions.push(`m.division = $${matchParameters.length}::public.team_division`);
      }
      const finishedMatches = await database.query(
        `SELECT m.sport_id AS "sportId", m.naipe, m.division,
          m.home_team_id AS "homeTeamId", m.away_team_id AS "awayTeamId",
          m.home_score AS "homeScore", m.away_score AS "awayScore"
         FROM public.matches m WHERE ${matchConditions.join(" AND ")}`,
        matchParameters,
      );

      const latestEdition = await database.query(
        `SELECT id FROM public.championship_bracket_editions
         WHERE championship_id = $1 AND season_year = $2
         ORDER BY reprogramming_revision DESC, created_at DESC LIMIT 1`,
        [championshipId, seasonYear],
      );
      const editionId = latestEdition.rows[0]?.id;
      const manualRows = editionId
        ? await database.query(
            `SELECT c.sport_id AS "sportId", c.naipe, c.division,
              rt.team_id AS "teamId", MIN(rt.draw_order)::int AS "drawOrder"
             FROM public.championship_bracket_tie_break_resolution_teams rt
             JOIN public.championship_bracket_tie_break_resolutions r ON r.id = rt.resolution_id
             JOIN public.championship_bracket_competitions c ON c.id = r.competition_id
             WHERE r.bracket_edition_id = $1
             GROUP BY c.sport_id, c.naipe, c.division, rt.team_id`,
            [editionId],
          )
        : { rows: [] as Record<string, unknown>[], count: 0 };

      const grouped = new Map<string, StandingRow[]>();
      for (const row of collectiveResult.rows.map((item) => normalizeStanding(item))) {
        const key = groupKey(row);
        const list = grouped.get(key) ?? [];
        list.push(row);
        grouped.set(key, list);
      }

      const rankedCollective = [...grouped.values()].flatMap((rows) => {
        const reference = rows[0]!;
        const key = groupKey(reference);
        const groupMatches: FinishedMatchForTieBreak[] = finishedMatches.rows
          .filter(
            (match) =>
              `${String(match.sportId)}:${String(match.naipe)}:${
                typeof match.division == "string" ? match.division : "WITHOUT_DIVISION"
              }` === key,
          )
          .map((match) => ({
            homeTeamId: String(match.homeTeamId),
            awayTeamId: String(match.awayTeamId),
            homeScore: toNumber(match.homeScore),
            awayScore: toNumber(match.awayScore),
          }));
        const manualDrawOrder = new Map<string, number>();
        for (const manual of manualRows.rows) {
          const manualKey = `${String(manual.sportId)}:${String(manual.naipe)}:${
            typeof manual.division == "string" ? manual.division : "WITHOUT_DIVISION"
          }`;
          if (manualKey === key) {
            manualDrawOrder.set(String(manual.teamId), toNumber(manual.drawOrder));
          }
        }
        const cascade = resolveTieBreakCascade(
          reference.legacyRule,
          reference.classificationPolicy,
        );
        return rankStandings(rows, cascade, groupMatches, manualDrawOrder).map((row, index) => {
          const { legacyRule: _legacyRule, classificationPolicy: _policy, ...publicRow } = row;
          return { ...publicRow, position: index + 1, tieBreakCascade: cascade };
        });
      });

      const individualParameters: unknown[] = [championshipId, seasonYear];
      const individualConditions = ["st.championship_id = $1", "st.season_year = $2"];
      if (sportId) {
        individualParameters.push(sportId);
        individualConditions.push(`st.sport_id = $${individualParameters.length}`);
      }
      if (naipe) {
        individualParameters.push(naipe);
        individualConditions.push(`st.naipe = $${individualParameters.length}::public.match_naipe`);
      }
      if (division) {
        individualParameters.push(division);
        individualConditions.push(
          `st.division = $${individualParameters.length}::public.team_division`,
        );
      }
      const individualResult = await database.query(
        `SELECT st.id, st.championship_id AS "championshipId",
          st.season_year AS "seasonYear", st.sport_id AS "sportId",
          sp.name AS "sportName", sp.code AS "sportCode", st.naipe, st.division,
          st.team_id AS "teamId", t.name AS "teamName", t.city AS "teamCity",
          st.total_points AS "totalPoints", st.scored_events_count AS "scoredEventsCount",
          st.first_places AS "firstPlaces", st.second_places AS "secondPlaces",
          st.third_places AS "thirdPlaces", st.relay_points_total AS "relayPointsTotal"
         FROM public.championship_individual_team_standings st
         JOIN public.teams t ON t.id = st.team_id
         JOIN public.sports sp ON sp.id = st.sport_id
         WHERE ${individualConditions.join(" AND ")}
         ORDER BY sp.name, st.naipe, st.division NULLS FIRST, st.total_points DESC,
           st.first_places DESC, st.second_places DESC, st.third_places DESC, t.name ASC`,
        individualParameters,
      );

      const individualGroups = new Map<string, IndividualStandingRow[]>();
      for (const raw of individualResult.rows) {
        const row: IndividualStandingRow = {
          id: String(raw.id),
          championshipId: String(raw.championshipId),
          seasonYear: toNumber(raw.seasonYear),
          sportId: String(raw.sportId),
          sportName: String(raw.sportName),
          sportCode: typeof raw.sportCode == "string" ? raw.sportCode : null,
          naipe: String(raw.naipe),
          division: typeof raw.division == "string" ? raw.division : null,
          teamId: String(raw.teamId),
          teamName: String(raw.teamName),
          teamCity: String(raw.teamCity ?? ""),
          totalPoints: toNumber(raw.totalPoints),
          scoredEventsCount: toNumber(raw.scoredEventsCount),
          firstPlaces: toNumber(raw.firstPlaces),
          secondPlaces: toNumber(raw.secondPlaces),
          thirdPlaces: toNumber(raw.thirdPlaces),
          relayPointsTotal: toNumber(raw.relayPointsTotal),
          source: "INDIVIDUAL",
        };
        const key = `${row.sportId}:${row.naipe}:${row.division ?? "WITHOUT_DIVISION"}`;
        const list = individualGroups.get(key) ?? [];
        list.push(row);
        individualGroups.set(key, list);
      }
      const rankedIndividual = [...individualGroups.values()].flatMap((rows) =>
        rows.map((row, index) => ({ ...row, position: index + 1 })),
      );

      const data = [...rankedCollective, ...rankedIndividual];
      const total = data.length;
      response.status(200).json({
        data: data.slice(offset, offset + pageSize),
        meta: {
          page,
          pageSize,
          total,
          totalPages: Math.ceil(total / pageSize),
          ordering: "backend-authoritative",
        },
      });
    } catch (error) {
      next(error);
    }
  });

  return router;
}
