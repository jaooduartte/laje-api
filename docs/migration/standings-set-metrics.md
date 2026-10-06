# Standing volleyball metrics compatibility

The production Supabase schema and the migrated RDS schema do not persist `sets_for`,
`sets_against`, `rally_points_for` or `rally_points_against` on `public.standings`.
The dedicated API therefore derives those four read metrics from finished matches and
`public.match_sets` instead of assuming columns that do not exist.

This keeps the API contract required by the frontend and tie-break ranking while
preserving schema parity with the source database. Recalculation writes only the
columns that are actually part of `public.standings`.
