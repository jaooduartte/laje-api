-- LAJE-126: triggers do motor exato v8.
DROP TRIGGER IF EXISTS championship_bracket_preview_reorganization_stage_event_trigger ON championship_bracket_preview_private.jobs;
CREATE TRIGGER championship_bracket_preview_reorganization_stage_event_trigger AFTER UPDATE OF stage ON championship_bracket_preview_private.jobs FOR EACH ROW WHEN ((new.stage ~~ 'Reorganizando grade:%'::text OR new.stage ~~ 'Reorganizando slots estruturais:%'::text) AND COALESCE(old.stage, ''::text) !~~ 'Reorganizando grade:%'::text AND COALESCE(old.stage, ''::text) !~~ 'Reorganizando slots estruturais:%'::text) EXECUTE FUNCTION championship_bracket_preview_private.record_reorganization_stage_event();

DROP TRIGGER IF EXISTS championship_bracket_preview_set_failed_completed_at ON championship_bracket_preview_private.jobs;
CREATE TRIGGER championship_bracket_preview_set_failed_completed_at BEFORE INSERT OR UPDATE OF status ON championship_bracket_preview_private.jobs FOR EACH ROW EXECUTE FUNCTION championship_bracket_preview_private.set_failed_preview_job_completed_at();

DROP TRIGGER IF EXISTS sync_failed_v8_processed_slots_trigger ON championship_bracket_preview_private.jobs;
CREATE TRIGGER sync_failed_v8_processed_slots_trigger BEFORE UPDATE OF status ON championship_bracket_preview_private.jobs FOR EACH ROW EXECUTE FUNCTION championship_bracket_preview_private.sync_failed_v8_processed_slots();

DROP TRIGGER IF EXISTS championship_bracket_preview_knockout_match_scheduled_event_tri ON championship_bracket_preview_private.knockout_matches;
CREATE TRIGGER championship_bracket_preview_knockout_match_scheduled_event_tri AFTER UPDATE OF scheduled_date ON championship_bracket_preview_private.knockout_matches FOR EACH ROW EXECUTE FUNCTION championship_bracket_preview_private.record_knockout_match_scheduled_event();

DROP TRIGGER IF EXISTS championship_bracket_preview_group_match_scheduled_event_trigge ON championship_bracket_preview_private.matches;
CREATE TRIGGER championship_bracket_preview_group_match_scheduled_event_trigge AFTER UPDATE OF assigned ON championship_bracket_preview_private.matches FOR EACH ROW EXECUTE FUNCTION championship_bracket_preview_private.record_group_match_scheduled_event();

DROP TRIGGER IF EXISTS championship_bracket_preview_normalize_relocation_metric_rest_g ON championship_bracket_preview_private.relocation_attempt_metrics;
CREATE TRIGGER championship_bracket_preview_normalize_relocation_metric_rest_g BEFORE INSERT ON championship_bracket_preview_private.relocation_attempt_metrics FOR EACH ROW EXECUTE FUNCTION championship_bracket_preview_private.normalize_relocation_metric_rest_gap();
