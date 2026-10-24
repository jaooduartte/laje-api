-- LAJE-150: migrate selected mandatory sport-result safeguards from Supabase to RDS.
-- These functions are native PostgreSQL and do not require Supabase Auth, Realtime or extensions.
-- Run as a new operational migration; do not edit the immutable baseline or older migrations.
-- Explicitly NOT porting generic conflict trigger until dependencies and schedule behavior are tested.

-- Source: public.validate_championship_knockout_match_finish
CREATE OR REPLACE FUNCTION public.validate_championship_knockout_match_finish()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  is_penalty_shootout_knockout_match BOOLEAN := false;
BEGIN
  IF NEW.status != 'FINISHED'::public.match_status THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.sports AS sports_table
      ON sports_table.id = NEW.sport_id
    WHERE bracket_matches_table.match_id = NEW.id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND sports_table.code IN ('FUTEBOL_SOCIETY', 'BEACH_SOCCER', 'FUTSAL')
  )
  INTO is_penalty_shootout_knockout_match;

  IF NEW.home_score = NEW.away_score THEN
    IF is_penalty_shootout_knockout_match
      AND NEW.home_penalty_score IS NOT NULL
      AND NEW.away_penalty_score IS NOT NULL
      AND NEW.home_penalty_score != NEW.away_penalty_score THEN
      NEW.resolved_tie_break_winner_team_id := CASE
        WHEN NEW.home_penalty_score > NEW.away_penalty_score THEN NEW.home_team_id
        ELSE NEW.away_team_id
      END;
      RETURN NEW;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.championship_bracket_matches AS bracket_matches_table
      WHERE bracket_matches_table.match_id = NEW.id
        AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    ) THEN
      RAISE EXCEPTION 'Jogos do mata-mata não podem terminar empatados.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS validate_championship_knockout_match_finish_trigger ON public.matches;
CREATE TRIGGER validate_championship_knockout_match_finish_trigger BEFORE UPDATE OF status, home_score, away_score, home_penalty_score, away_penalty_score, resolved_tie_break_winner_team_id ON matches FOR EACH ROW EXECUTE FUNCTION validate_championship_knockout_match_finish();

-- Source: public.validate_interlaje_volleyball_match_finish
CREATE OR REPLACE FUNCTION public.validate_interlaje_volleyball_match_finish()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  championship_code public.championship_code;
  normalized_sport_name TEXT;
  is_interlaje_volleyball_final BOOLEAN := false;
BEGIN
  IF NEW.status <> 'FINISHED'::public.match_status
    OR OLD.status = 'FINISHED'::public.match_status THEN
    RETURN NEW;
  END IF;

  SELECT
    championships_table.code,
    public.normalize_sport_name(sports_table.name)
  INTO championship_code, normalized_sport_name
  FROM public.championships AS championships_table
  JOIN public.sports AS sports_table ON sports_table.id = NEW.sport_id
  WHERE championships_table.id = NEW.championship_id
  LIMIT 1;

  SELECT EXISTS (
    SELECT 1
    FROM public.championship_bracket_matches AS bracket_matches_table
    WHERE bracket_matches_table.match_id = NEW.id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_third_place = false
      AND bracket_matches_table.next_bracket_match_id IS NULL
  )
  INTO is_interlaje_volleyball_final;

  IF championship_code = 'INTERLAJE'::public.championship_code
    AND normalized_sport_name = 'voleibol'
    AND NOT (
      (
        is_interlaje_volleyball_final
        AND (
          (NEW.home_score = 3 AND NEW.away_score IN (0, 1, 2))
          OR (NEW.away_score = 3 AND NEW.home_score IN (0, 1, 2))
        )
      )
      OR (
        NOT is_interlaje_volleyball_final
        AND (
          (NEW.home_score = 2 AND NEW.away_score IN (0, 1))
          OR (NEW.away_score = 2 AND NEW.home_score IN (0, 1))
        )
      )
    ) THEN
    IF is_interlaje_volleyball_final THEN
      RAISE EXCEPTION 'Na final do Voleibol do INTERLAJE, a partida deve terminar em 3 × 0, 3 × 1 ou 3 × 2.';
    END IF;

    RAISE EXCEPTION 'No Voleibol do INTERLAJE, a partida deve terminar em 2 × 0 ou 2 × 1.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS validate_interlaje_volleyball_match_finish_trigger ON public.matches;
CREATE TRIGGER validate_interlaje_volleyball_match_finish_trigger BEFORE UPDATE OF status ON matches FOR EACH ROW EXECUTE FUNCTION validate_interlaje_volleyball_match_finish();

