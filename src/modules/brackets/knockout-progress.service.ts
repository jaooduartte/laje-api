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
    `SELECT id, match_id AS "matchId",
            home_team_id AS "homeTeamId", away_team_id AS "awayTeamId",
            source_home_bracket_match_id AS "sourceHomeId",
            source_away_bracket_match_id AS "sourceAwayId"
       FROM public.championship_bracket_matches WHERE id = $1 FOR UPDATE`,
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
}
