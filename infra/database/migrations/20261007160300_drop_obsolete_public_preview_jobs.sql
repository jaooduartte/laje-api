-- LAJE-126: remove o protótipo de tabela pública usado antes da portabilidade do motor exato v8.
-- O estado transitório correto vive exclusivamente em championship_bracket_preview_private.
DROP TABLE IF EXISTS public.championship_bracket_preview_jobs;
