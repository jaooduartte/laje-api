ALTER TABLE championship_bracket_preview_private.job_events
  ALTER COLUMN id
  SET DEFAULT nextval('championship_bracket_preview_private.job_events_id_seq'::regclass);

ALTER SEQUENCE championship_bracket_preview_private.job_events_id_seq
  OWNED BY championship_bracket_preview_private.job_events.id;
