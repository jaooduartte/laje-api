import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalBoolean,
  optionalEnum,
  requireEnum,
  requireInteger,
  requireRecord,
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

const NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;
const THIRD_PLACE_MODES = ["NONE", "MATCH", "CHAMPION_SEMIFINAL_LOSER"] as const;
const PAIRING_MODES = ["LINEAR", "RANKING_ALTERNATING", "CLASSIC_SEEDED"] as const;

type Naipe = (typeof NAIPES)[number];
type Division = (typeof DIVISIONS)[number];
type ThirdPlaceMode = (typeof THIRD_PLACE_MODES)[number];
type PairingMode = (typeof PAIRING_MODES)[number];

interface GroupInput {
  groupNumber: number;
  teamIds: string[];
}

interface CompetitionInput {
  sportId: string;
  naipe: Naipe;
  division: Division | null;
  groupsCount: number;
  qualifiersPerGroup: number;
  thirdPlaceMode: ThirdPlaceMode;
  shouldCompleteKnockoutWithBestSecondPlacedTeams: boolean;
  knockoutPairingMode: PairingMode;
  groups: GroupInput[];
}

function parseGenerationBody(body: unknown) {
  const payload = requireRecord(body);
  const seasonYear = requireInteger(payload.seasonYear, "seasonYear", {
    min: 2000,
    max: 2100,
  });
  if (!Array.isArray(payload.competitions) || payload.competitions.length === 0) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "Informe ao menos uma competição para gerar a chave.",
    );
  }

  const competitions: CompetitionInput[] = payload.competitions.map(
    (raw, competitionIndex) => {
      const item = requireRecord(raw, `Competição ${competitionIndex + 1} inválida.`);
      const groupsCount = requireInteger(
        item.groupsCount,
        `competitions[${competitionIndex}].groupsCount`,
        { min: 1, max: 32 },
      );
      const qualifiersPerGroup = requireInteger(
        item.qualifiersPerGroup,
        `competitions[${competitionIndex}].qualifiersPerGroup`,
        { min: 1, max: 16 },
      );
      if (!Array.isArray(item.groups) || item.groups.length !== groupsCount) {
        throw new ApiError(
          422,
          "VALIDATION_ERROR",
          `A competição ${competitionIndex + 1} deve conter exatamente ${groupsCount} grupos.`,
        );
      }
      const seenTeams = new Set<string>();
      const groups = item.groups.map((rawGroup, groupIndex) => {
        const group = requireRecord(rawGroup, `Grupo ${groupIndex + 1} inválido.`);
        const groupNumber = requireInteger(
          group.groupNumber,
          `groups[${groupIndex}].groupNumber`,
          { min: 1, max: 64 },
        );
        if (!Array.isArray(group.teamIds) || group.teamIds.length < 2) {
          throw new ApiError(
            422,
            "VALIDATION_ERROR",
            `O grupo ${groupNumber} deve possuir pelo menos dois times.`,
          );
        }
        const teamIds = group.teamIds.map((teamId, teamIndex) =>
          requireUuid(teamId, `groups[${groupIndex}].teamIds[${teamIndex}]`),
        );
        for (const teamId of teamIds) {
          if (seenTeams.has(teamId)) {
            throw new ApiError(
              422,
              "VALIDATION_ERROR",
              "Um time não pode aparecer em mais de um grupo da mesma competição.",
            );
          }
          seenTeams.add(teamId);
        }
        return { groupNumber, teamIds };
      });
      return {
        sportId: requireUuid(item.sportId, `competitions[${competitionIndex}].sportId`),
        naipe: requireEnum(
          item.naipe,
          `competitions[${competitionIndex}].naipe`,
          NAIPES,
        ),
        division:
          item.division == null
            ? null
            : requireEnum(
                item.division,
                `competitions[${competitionIndex}].division`,
                DIVISIONS,
              ),
        groupsCount,
        qualifiersPerGroup,
        thirdPlaceMode:
          item.thirdPlaceMode == null
            ? "NONE"
            : requireEnum(
                item.thirdPlaceMode,
                `competitions[${competitionIndex}].thirdPlaceMode`,
                THIRD_PLACE_MODES,
              ),
        shouldCompleteKnockoutWithBestSecondPlacedTeams:
          optionalBoolean(
            item.shouldCompleteKnockoutWithBestSecondPlacedTeams,
            "shouldCompleteKnockoutWithBestSecondPlacedTeams",
          ) ?? false,
        knockoutPairingMode:
          optionalEnum(item.knockoutPairingMode, "knockoutPairingMode", PAIRING_MODES) ??
          "CLASSIC_SEEDED",
        groups,
      };
    },
  );

  const payloadSnapshot =
    payload.payloadSnapshot &&
    typeof payload.payloadSnapshot == "object" &&
    !Array.isArray(payload.payloadSnapshot)
      ? (payload.payloadSnapshot as Record<string, unknown>)
      : payload;

  return { seasonYear, competitions, payloadSnapshot };
}

async function ensureChampionshipAndTeams(
  executor: DatabaseQueryExecutor,
  championshipId: string,
  competitions: CompetitionInput[],
): Promise<void> {
  const championship = await executor.query(
    "SELECT id FROM public.championships WHERE id = $1",
    [championshipId],
  );
  if (!championship.rows[0]) {
    throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
  }

  const teamIds = [
    ...new Set(
      competitions.flatMap((competition) =>
        competition.groups.flatMap((group) => group.teamIds),
      ),
    ),
  ];
  const teams = await executor.query(
    "SELECT id FROM public.teams WHERE id = ANY($1::uuid[]) AND is_active = true",
    [teamIds],
  );
  if (teams.rows.length !== teamIds.length) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "A configuração contém time inexistente ou inativo.",
    );
  }

  const sportIds = [...new Set(competitions.map((competition) => competition.sportId))];
  const sports = await executor.query(
    `SELECT sport_id AS id FROM public.championship_sports
     WHERE championship_id = $1 AND sport_id = ANY($2::uuid[])`,
    [championshipId, sportIds],
  );
  if (sports.rows.length !== sportIds.length) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "A configuração contém modalidade não vinculada ao campeonato.",
    );
  }
}

async function auditGeneration(
  executor: DatabaseQueryExecutor,
  request: AuthenticatedRequest,
  edition: DatabaseRow,
): Promise<void> {
  const principal = request.authPrincipal;
  await executor.query(
    `INSERT INTO public.admin_action_logs
      (actor_user_id, actor_email, actor_role, action_type, resource_table,
       record_id, description, new_data, metadata, actor_name)
     VALUES ($1, $2, $3::public.app_role, 'INSERT', 'championship_bracket_editions',
       $4, $5, $6::jsonb, '{"source":"laje-api","task":"LAJE-86"}'::jsonb, $7)`,
    [
      principal?.userId ?? null,
      principal?.user.email ?? null,
      principal?.user.role ?? null,
      String(edition.id),
      "Chave de grupos gerada via laje-api.",
      JSON.stringify(edition),
      principal?.user.profile?.name ?? null,
    ],
  );
}

async function loadBracketView(championshipId: string, seasonYear: number) {
  const editionResult = await database.query(
    `SELECT id, championship_id AS "championshipId", season_year AS "seasonYear",
      status, payload_snapshot AS "payloadSnapshot",
      reprogramming_revision AS "revision", created_at::text AS "createdAt",
      updated_at::text AS "updatedAt"
     FROM public.championship_bracket_editions
     WHERE championship_id = $1 AND season_year = $2
     ORDER BY reprogramming_revision DESC, created_at DESC LIMIT 1`,
    [championshipId, seasonYear],
  );
  const edition = editionResult.rows[0] ?? null;
  if (!edition) return { edition: null, competitions: [] };

  const competitions = await database.query(
    `SELECT c.id, c.sport_id AS "sportId", s.name AS "sportName", c.naipe,
      c.division, c.groups_count AS "groupsCount",
      c.qualifiers_per_group AS "qualifiersPerGroup",
      c.should_complete_knockout_with_best_second_placed_teams AS
        "shouldCompleteKnockoutWithBestSecondPlacedTeams",
      c.knockout_pairing_mode AS "knockoutPairingMode",
      c.third_place_mode AS "thirdPlaceMode"
     FROM public.championship_bracket_competitions c
     JOIN public.sports s ON s.id = c.sport_id
     WHERE c.bracket_edition_id = $1
     ORDER BY s.name, c.naipe, c.division NULLS FIRST`,
    [edition.id],
  );
  const groups = await database.query(
    `SELECT g.id, g.competition_id AS "competitionId", g.group_number AS "groupNumber"
     FROM public.championship_bracket_groups g
     JOIN public.championship_bracket_competitions c ON c.id = g.competition_id
     WHERE c.bracket_edition_id = $1 ORDER BY g.group_number`,
    [edition.id],
  );
  const groupTeams = await database.query(
    `SELECT gt.group_id AS "groupId", gt.team_id AS "teamId",
      t.name AS "teamName", t.city AS "teamCity", gt.position
     FROM public.championship_bracket_group_teams gt
     JOIN public.teams t ON t.id = gt.team_id
     JOIN public.championship_bracket_groups g ON g.id = gt.group_id
     JOIN public.championship_bracket_competitions c ON c.id = g.competition_id
     WHERE c.bracket_edition_id = $1 ORDER BY gt.position`,
    [edition.id],
  );
  const bracketMatches = await database.query(
    `SELECT bm.id, bm.competition_id AS "competitionId", bm.group_id AS "groupId",
      bm.phase, bm.round_number AS "roundNumber", bm.slot_number AS "slotNumber",
      bm.match_id AS "matchId", bm.is_bye AS "isBye",
      bm.is_third_place AS "isThirdPlace", m.status,
      m.scheduled_date::text AS "scheduledDate", m.queue_position AS "queuePosition",
      m.scheduled_slot AS "scheduledSlot", m.start_time::text AS "startTime",
      m.end_time::text AS "endTime", m.location, m.court_name AS "courtName",
      COALESCE(m.home_team_id, bm.home_team_id) AS "homeTeamId",
      COALESCE(m.away_team_id, bm.away_team_id) AS "awayTeamId",
      ht.name AS "homeTeamName", at.name AS "awayTeamName",
      COALESCE(m.resolved_tie_break_winner_team_id, bm.winner_team_id) AS "winnerTeamId",
      wt.name AS "winnerTeamName"
     FROM public.championship_bracket_matches bm
     LEFT JOIN public.matches m ON m.id = bm.match_id
     LEFT JOIN public.teams ht ON ht.id = COALESCE(m.home_team_id, bm.home_team_id)
     LEFT JOIN public.teams at ON at.id = COALESCE(m.away_team_id, bm.away_team_id)
     LEFT JOIN public.teams wt
       ON wt.id = COALESCE(m.resolved_tie_break_winner_team_id, bm.winner_team_id)
     WHERE bm.bracket_edition_id = $1
     ORDER BY bm.phase, bm.round_number, bm.slot_number`,
    [edition.id],
  );

  return {
    edition,
    competitions: competitions.rows.map((competition) => ({
      ...competition,
      groups: groups.rows
        .filter((group) => group.competitionId === competition.id)
        .map((group) => ({
          id: group.id,
          groupNumber: group.groupNumber,
          teams: groupTeams.rows
            .filter((team) => team.groupId === group.id)
            .map(({ groupId: _groupId, ...team }) => team),
          matches: bracketMatches.rows
            .filter(
              (match) =>
                match.competitionId === competition.id &&
                match.groupId === group.id &&
                match.phase === "GROUP_STAGE",
            )
            .map(
              ({ competitionId: _competitionId, groupId: _groupId, phase: _phase, ...match }) =>
                match,
            ),
        })),
      knockoutMatches: bracketMatches.rows
        .filter(
          (match) =>
            match.competitionId === competition.id && match.phase === "KNOCKOUT",
        )
        .map(
          ({ competitionId: _competitionId, groupId: _groupId, phase: _phase, ...match }) =>
            match,
        ),
    })),
  };
}

export function createBracketRouter(authService: AuthService): Router {
  const router = Router({ mergeParams: true });
  const requireAuthentication = createRequireAuthentication(authService);

  router.get("/", async (request, response, next) => {
    try {
      const inheritedParams = request.params as Record<string, unknown>;
      const championshipId = requireUuid(inheritedParams.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", {
        min: 2000,
        max: 2100,
      });
      const championship = await database.query(
        "SELECT id FROM public.championships WHERE id = $1",
        [championshipId],
      );
      if (!championship.rows[0]) {
        throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
      }
      response.status(200).json({
        data: await loadBracketView(championshipId, seasonYear),
      });
    } catch (error) {
      next(error);
    }
  });

  router.post(
    "/generate",
    requireAuthentication,
    requirePermission("bracket_setup", "EDIT"),
    async (request, response, next) => {
      try {
        const inheritedParams = request.params as Record<string, unknown>;
        const championshipId = requireUuid(
          inheritedParams.championshipId,
          "championshipId",
        );
        const input = parseGenerationBody(request.body);
        await database.transaction(async (tx) => {
          await ensureChampionshipAndTeams(tx, championshipId, input.competitions);
          const existing = await tx.query(
            `SELECT id FROM public.championship_bracket_editions
             WHERE championship_id = $1 AND season_year = $2 LIMIT 1`,
            [championshipId, input.seasonYear],
          );
          if (existing.rows[0]) {
            throw new ApiError(
              409,
              "BRACKET_ALREADY_EXISTS",
              "Já existe uma edição de chave para este campeonato e temporada. Reprogramações devem usar o fluxo específico de reprogramação.",
            );
          }

          const actorUserId =
            (request as AuthenticatedRequest).authPrincipal?.userId ?? null;
          const editionResult = await tx.query(
            `INSERT INTO public.championship_bracket_editions
              (championship_id, season_year, status, payload_snapshot, created_by, updated_by)
             VALUES ($1, $2, 'GROUPS_GENERATED', $3::jsonb, $4, $4)
             RETURNING id, championship_id AS "championshipId",
               season_year AS "seasonYear", status,
               payload_snapshot AS "payloadSnapshot",
               created_at AS "createdAt", updated_at AS "updatedAt"`,
            [
              championshipId,
              input.seasonYear,
              JSON.stringify(input.payloadSnapshot),
              actorUserId,
            ],
          );
          const edition = editionResult.rows[0]!;

          for (const competitionInput of input.competitions) {
            const competitionResult = await tx.query(
              `INSERT INTO public.championship_bracket_competitions
                (bracket_edition_id, sport_id, naipe, division, groups_count,
                 qualifiers_per_group, third_place_mode,
                 should_complete_knockout_with_best_second_placed_teams,
                 knockout_pairing_mode)
               VALUES ($1, $2, $3::public.match_naipe, $4::public.team_division,
                 $5, $6, $7::public.bracket_third_place_mode, $8, $9)
               RETURNING id`,
              [
                edition.id,
                competitionInput.sportId,
                competitionInput.naipe,
                competitionInput.division,
                competitionInput.groupsCount,
                competitionInput.qualifiersPerGroup,
                competitionInput.thirdPlaceMode,
                competitionInput.shouldCompleteKnockoutWithBestSecondPlacedTeams,
                competitionInput.knockoutPairingMode,
              ],
            );
            const competitionId = String(competitionResult.rows[0]!.id);

            for (const groupInput of competitionInput.groups) {
              const groupResult = await tx.query(
                `INSERT INTO public.championship_bracket_groups
                  (competition_id, group_number) VALUES ($1, $2) RETURNING id`,
                [competitionId, groupInput.groupNumber],
              );
              const groupId = String(groupResult.rows[0]!.id);

              for (let index = 0; index < groupInput.teamIds.length; index += 1) {
                await tx.query(
                  `INSERT INTO public.championship_bracket_group_teams
                    (group_id, team_id, position) VALUES ($1, $2, $3)`,
                  [groupId, groupInput.teamIds[index], index + 1],
                );
              }

              let slotNumber = 1;
              for (
                let homeIndex = 0;
                homeIndex < groupInput.teamIds.length - 1;
                homeIndex += 1
              ) {
                for (
                  let awayIndex = homeIndex + 1;
                  awayIndex < groupInput.teamIds.length;
                  awayIndex += 1
                ) {
                  const matchResult = await tx.query(
                    `INSERT INTO public.matches
                      (sport_id, home_team_id, away_team_id, championship_id,
                       season_year, division, naipe, supports_cards, location)
                     SELECT $1, $2, $3, c.id, $4, $5::public.team_division,
                       $6::public.match_naipe, COALESCE(cs.supports_cards, false),
                       c.default_location
                     FROM public.championships c
                     LEFT JOIN public.championship_sports cs
                       ON cs.championship_id = c.id AND cs.sport_id = $1
                     WHERE c.id = $7 RETURNING id`,
                    [
                      competitionInput.sportId,
                      groupInput.teamIds[homeIndex],
                      groupInput.teamIds[awayIndex],
                      input.seasonYear,
                      competitionInput.division,
                      competitionInput.naipe,
                      championshipId,
                    ],
                  );
                  const matchId = String(matchResult.rows[0]!.id);
                  await tx.query(
                    `INSERT INTO public.championship_bracket_matches
                      (bracket_edition_id, competition_id, group_id, phase,
                       round_number, slot_number, match_id, home_team_id, away_team_id)
                     VALUES ($1, $2, $3, 'GROUP_STAGE', 1, $4, $5, $6, $7)`,
                    [
                      edition.id,
                      competitionId,
                      groupId,
                      slotNumber,
                      matchId,
                      groupInput.teamIds[homeIndex],
                      groupInput.teamIds[awayIndex],
                    ],
                  );
                  slotNumber += 1;
                }
              }
            }
          }

          await auditGeneration(tx, request as AuthenticatedRequest, edition);
        });

        response.status(201).json({
          data: await loadBracketView(championshipId, input.seasonYear),
        });
      } catch (error) {
        next(error);
      }
    },
  );

  return router;
}
