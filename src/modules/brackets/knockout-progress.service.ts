import { ApiError } from "../../common/errors/api-error.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../database/types.js";

/**
 * LAJE-150: propagate a finished knockout result through explicit source/next links.
 * Never guess the next pairing, allocate an invented court, or overwrite a live match.
 * Group-to-knockout bracket creation remains a separate algorithm and validation step.
 */
export async function propagateExistingKnockoutResult(
  executor: DatabaseQueryExecutor,
  match: DatabaseRow,
): Promise<void> {
  const matchId = String(match.id);
  const current = await executor.query(
    `SELECT id, winner_team_id AS "winnerTeamId",
            next_bracket_match_id AS "nextBracketMatchId"
       FROM public.championship_bracket_matches
      WHERE match_id = $1 AND phase = 'KNOCKOUT'
      FOR UPDATE`,
    [matchId],
  );
  const source = current.rows[0];
  if (!source) return;

  const homeTeamId = String(match.homeTeamId);
  const awayTeamId = String(match.awayTeamId);
  if (match.isDoubleWalkover === true) {
    throw new ApiError(
      409,
      "KNOCKOUT_UNRESOLVED",
      "Mata-mata com W.O. duplo exige resolução administrativa.",
    );
  }
  let winnerTeamId: string;
  if (match.isWalkover === true) {
    const loser = String(match.walkoverLoserTeamId ?? "");
    if (loser !== homeTeamId && loser !== awayTeamId) {
      throw new ApiError(
        422,
        "INVALID_WALKOVER_LOSER",
        "A equipe perdedora do W.O. deve disputar a partida.",
      );
    }
    winnerTeamId = loser === homeTeamId ? awayTeamId : homeTeamId;
  } else {
    const home = Number(match.homeScore);
    const away = Number(match.awayScore);
    if (home > away) winnerTeamId = homeTeamId;
    else if (away > home) winnerTeamId = awayTeamId;
    else {
      const tieBreakWinner = String(match.resolvedTieBreakWinnerTeamId ?? "");
      if (tieBreakWinner !== homeTeamId && tieBreakWinner !== awayTeamId) {
        throw new ApiError(
          409,
          "KNOCKOUT_UNRESOLVED",
          "O empate eliminatório exige vencedor validado.",
        );
      }
      winnerTeamId = tieBreakWinner;
    }
  }

  if (source.winnerTeamId && String(source.winnerTeamId) !== winnerTeamId) {
    throw new ApiError(
      409,
      "KNOCKOUT_WINNER_CONFLICT",
      "O vencedor já registrado precisa de correção administrativa do chaveamento.",
    );
  }
  await executor.query(
    "UPDATE public.championship_bracket_matches SET winner_team_id = $2 WHERE id = $1",
    [source.id, winnerTeamId],
  );

  if (!source.nextBracketMatchId) return;

  const targetResult = await executor.query(
    `SELECT bm.id, bm.match_id AS "matchId",
            bm.home_team_id AS "homeTeamId", bm.away_team_id AS "awayTeamId",
            bm.source_home_bracket_match_id AS "sourceHomeId",
            bm.source_away_bracket_match_id AS "sourceAwayId",
            bm.planned_scheduled_date AS "plannedDate",
            bm.planned_scheduled_slot AS "plannedSlot",
            bm.planned_queue_position AS "plannedQueue",
            bm.planned_start_time AS "plannedStart",
            bm.planned_end_time AS "plannedEnd",
            bm.planned_location_group_id AS "plannedLocationGroupId",
            bm.planned_court_group_id AS "plannedCourtGroupId",
            bm.planned_location_name AS "plannedLocation",
            bm.planned_court_name AS "plannedCourt",
            comp.id AS "competitionId",
            ed.payload_snapshot ->> 'exact_preview_algorithm_version' AS "algorithmVersion"
       FROM public.championship_bracket_matches bm
       JOIN public.championship_bracket_competitions comp ON comp.id = bm.competition_id
       JOIN public.championship_bracket_editions ed ON ed.id = bm.bracket_edition_id
       WHERE bm.id = $1 FOR UPDATE OF bm`,
    [source.nextBracketMatchId],
  );
  const target = targetResult.rows[0];
  if (!target) {
    throw new ApiError(
      409,
      "KNOCKOUT_TARGET_NOT_FOUND",
      "A próxima partida eliminatória não existe.",
    );
  }

  const slot =
    String(target.sourceHomeId ?? "") === String(source.id)
      ? "home_team_id"
      : String(target.sourceAwayId ?? "") === String(source.id)
        ? "away_team_id"
        : null;
  if (!slot) {
    throw new ApiError(
      409,
      "KNOCKOUT_LINK_INCONSISTENT",
      "Não foi possível identificar o lado de avanço no chaveamento.",
    );
  }
  const currentTeam = slot === "home_team_id" ? target.homeTeamId : target.awayTeamId;
  if (currentTeam && String(currentTeam) !== winnerTeamId) {
    throw new ApiError(
      409,
      "KNOCKOUT_TARGET_CONFLICT",
      "A próxima fase já contém uma equipe diferente.",
    );
  }

  await executor.query(
    slot === "home_team_id"
      ? "UPDATE public.championship_bracket_matches SET home_team_id = $2 WHERE id = $1"
      : "UPDATE public.championship_bracket_matches SET away_team_id = $2 WHERE id = $1",
    [target.id, winnerTeamId],
  );

  const qualifiedHomeTeamId = slot === "home_team_id" ? winnerTeamId : target.homeTeamId;
  const qualifiedAwayTeamId = slot === "away_team_id" ? winnerTeamId : target.awayTeamId;
  if (
    qualifiedHomeTeamId &&
    qualifiedAwayTeamId &&
    String(qualifiedHomeTeamId) === String(qualifiedAwayTeamId)
  ) {
    throw new ApiError(409, "KNOCKOUT_DUPLICATE_TEAM", "Uma equipe não pode enfrentar a si mesma.");
  }

  // A preview can pre-create the public match. Never rewrite an already live result.
  if (target.matchId) {
    const changed = await executor.query(
      slot === "home_team_id"
        ? "UPDATE public.matches SET home_team_id = $2, updated_at = now() WHERE id = $1 AND status = 'SCHEDULED' RETURNING id"
        : "UPDATE public.matches SET away_team_id = $2, updated_at = now() WHERE id = $1 AND status = 'SCHEDULED' RETURNING id",
      [target.matchId, winnerTeamId],
    );
    if (changed.rows.length !== 1) {
      throw new ApiError(
        409,
        "KNOCKOUT_TARGET_ALREADY_STARTED",
        "Não é seguro alterar uma partida eliminatória já iniciada.",
      );
    }
  }

  // In exact-v8 the next round is a reserved slot. Materialize it only when
  // both previous winners and every published scheduling field are available.
  if (
    !target.matchId &&
    qualifiedHomeTeamId &&
    qualifiedAwayTeamId &&
    target.algorithmVersion === "async-exact-v8"
  ) {
    if (
      !target.plannedDate ||
      !target.plannedSlot ||
      !target.plannedQueue ||
      !target.plannedStart ||
      !target.plannedEnd ||
      !target.plannedLocationGroupId ||
      !target.plannedCourtGroupId ||
      !target.plannedLocation ||
      !target.plannedCourt
    ) {
      throw new ApiError(
        409,
        "KNOCKOUT_SCHEDULE_INCOMPLETE",
        "A partida eliminatória não possui programação estrutural completa.",
      );
    }

    const created = await executor.query(
      `INSERT INTO public.matches (
          championship_id, division, naipe, sport_id,
          home_team_id, away_team_id, location, court_name,
          scheduled_date, scheduled_slot, queue_position,
          scheduled_start_time, start_time, end_time,
          season_year, status, supports_cards
        )
        SELECT ed.championship_id, comp.division, comp.naipe, comp.sport_id,
               $2::uuid, $3::uuid, $4::text, $5::text,
               $6::date, $7::integer, $8::integer,
               (($6::date + $9::time) AT TIME ZONE 'America/Sao_Paulo'),
               (($6::date + $9::time) AT TIME ZONE 'America/Sao_Paulo'),
               (($6::date + $10::time) AT TIME ZONE 'America/Sao_Paulo'),
               ed.season_year, 'SCHEDULED'::public.match_status,
               COALESCE(cs.supports_cards, false)
        FROM public.championship_bracket_competitions comp
        JOIN public.championship_bracket_editions ed ON ed.id = comp.bracket_edition_id
        LEFT JOIN public.championship_sports cs
          ON cs.championship_id = ed.championship_id AND cs.sport_id = comp.sport_id
        WHERE comp.id = $1 RETURNING id`,
      [
        target.competitionId,
        qualifiedHomeTeamId,
        qualifiedAwayTeamId,
        target.plannedLocation,
        target.plannedCourt,
        target.plannedDate,
        target.plannedSlot,
        target.plannedQueue,
        target.plannedStart,
        target.plannedEnd,
      ],
    );
    if (created.rows.length !== 1) {
      throw new ApiError(409, "KNOCKOUT_CREATION_FAILED", "Competição eliminatória não encontrada.");
    }
    await executor.query(
      "UPDATE public.championship_bracket_matches SET match_id = $2 WHERE id = $1",
      [target.id, created.rows[0]!.id],
    );
  }
}
