CREATE OR REPLACE FUNCTION public.validate_championship_status_transition()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'PLANNING'::public.championship_status
    AND NEW.status IN ('IN_PROGRESS'::public.championship_status, 'FINISHED'::public.championship_status) THEN
    RAISE EXCEPTION 'O campeonato precisa passar por Configurando campeonato antes de ir para Em andamento ou Encerrado.';
  END IF;

  IF NEW.status = 'PLANNING'::public.championship_status
    AND current_setting('laje.allow_championship_planning_transition', true) IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'A mudança para Em breve exige confirmar o reset seguro da temporada atual.';
  END IF;

  IF NEW.status = 'FINISHED'::public.championship_status
    AND EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      WHERE matches_table.championship_id = NEW.id
        AND matches_table.season_year = NEW.current_season_year
        AND matches_table.status IN ('SCHEDULED'::public.match_status, 'LIVE'::public.match_status)
    ) THEN
    RAISE EXCEPTION 'Não é possível encerrar o campeonato enquanto existirem jogos agendados ou ao vivo na temporada atual.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS validate_championship_status_transition_trigger
  ON public.championships;

CREATE TRIGGER validate_championship_status_transition_trigger
BEFORE UPDATE OF status ON public.championships
FOR EACH ROW
EXECUTE FUNCTION public.validate_championship_status_transition();
