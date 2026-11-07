DO $migration$
BEGIN
  IF to_regclass('public.championship_sports') IS NULL THEN
    RETURN;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'championship_sports'
      AND column_name = 'show_estimated_start_time_on_cards'
  ) THEN
    ALTER TABLE public.championship_sports
      ADD COLUMN show_estimated_start_time_on_cards boolean NOT NULL DEFAULT false;

    UPDATE public.championship_sports AS championship_sports
    SET show_estimated_start_time_on_cards = true
    FROM public.sports AS sports
    WHERE sports.id = championship_sports.sport_id
      AND public.normalize_sport_name(sports.name) = 'beach soccer';
  ELSE
    ALTER TABLE public.championship_sports
      ALTER COLUMN show_estimated_start_time_on_cards SET DEFAULT false;

    UPDATE public.championship_sports
    SET show_estimated_start_time_on_cards = false
    WHERE show_estimated_start_time_on_cards IS NULL;

    ALTER TABLE public.championship_sports
      ALTER COLUMN show_estimated_start_time_on_cards SET NOT NULL;
  END IF;
END;
$migration$;
