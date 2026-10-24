import type { DatabaseQueryExecutor } from "../../database/types.js";

/**
 * Complete an exact-v8 competition only when all its groups are finished and
 * any required tie-breaks have been resolved. The original PostgreSQL engine
 * owns qualification, BYEs, best runners-up, group seeding and third place.
 *
 * Called inside the same transaction as a match finish so one unsuccessful
 * qualification cannot leave a partially-persisted knockout.
 */
export async function hydrateKnockoutAfterGroupFinish(
  executor: DatabaseQueryExecutor,
  matchId: string,
): Promise<number> {
  const groupMatches = await executor.query(
    `SELECT bm.competition_id AS "competitionId",
            bm.bracket_edition_id AS "editionId",
            ed.championship_id AS "championshipId"
       FROM public.championship_bracket_matches AS bm
       JOIN public.championship_bracket_editions AS ed
         ON ed.id = bm.bracket_edition_id
      WHERE bm.match_id = $1
        AND bm.phase = 'GROUP_STAGE'
        AND ed.payload_snapshot ->> 'exact_preview_algorithm_version' = 'async-exact-v8'
      FOR UPDATE OF ed`,
    [matchId],
  );

  for (const groupMatch of groupMatches.rows) {
    await executor.query(
      `SELECT public.hydrate_championship_bracket_preview_v8_knockout(
         $1::uuid, $2::uuid, $3::uuid
       ) AS competition_id`,
      [groupMatch.championshipId, groupMatch.competitionId, groupMatch.editionId],
    );
  }

  return groupMatches.rows.length;
}
