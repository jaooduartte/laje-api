-- LAJE-112 — função estrutural necessária para recriar índice de agenda.
-- Esta é a única rotina public mantida no baseline porque um índice do schema depende dela.
-- As demais regras/RPCs/triggers permanecem fora deste baseline e serão migradas por domínio para a laje-api.

CREATE OR REPLACE FUNCTION public.coerce_division_for_index(d team_division)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE STRICT
AS $function$
  SELECT d::text;
$function$;
