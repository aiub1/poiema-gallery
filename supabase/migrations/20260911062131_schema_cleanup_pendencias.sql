-- Closes the three open items in ARQUITETURA.md §15:
-- 1. profiles_full_name_not_blank was documented in §4 but never shipped
--    as a migration (fell outside the scope of the RLS fix).
-- 2. sessions had no protection against two sessions with the same name
--    in the same event.
-- 3. events.created_by has an `on delete restrict` FK with no supporting
--    index.

alter table public.profiles
  add constraint profiles_full_name_not_blank
  check (length(btrim(full_name)) > 0);

-- Normalized, not a plain unique(event_id, name): the real-world case this
-- guards against is accidental re-entry of the same session name with
-- different capitalization or stray whitespace, not two deliberately
-- distinct sessions that happen to differ only by case. See ADR 0008.
create unique index sessions_event_id_name_key
  on public.sessions (event_id, lower(btrim(name)));

create index events_created_by_idx on public.events (created_by);
