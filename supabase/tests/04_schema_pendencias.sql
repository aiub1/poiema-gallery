-- pgTAP — pendências fechadas do ARQUITETURA.md §15:
-- profiles_full_name_not_blank, unique (event_id, lower(btrim(name))) em
-- sessions, índice de apoio em events.created_by. Roda como postgres,
-- bypassando RLS de propósito: o alvo são as constraints de schema, não
-- policy.

begin;

create extension if not exists pgtap;

select plan(7);

-- fixtures: um profile e um evento, sem depender de seed.sql
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-0000-0000-00000000d001', 'authenticated', 'authenticated', 'test-schema-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Admin Schema', role = 'admin', is_active = true
  where id = 'd0000000-0000-0000-0000-00000000d001';

insert into public.events (id, name, slug, event_date, created_by) values
  ('d0000000-0000-0000-0000-00000000d0e1', 'Evento Schema 1', 'evento-schema-1', current_date, 'd0000000-0000-0000-0000-00000000d001'),
  ('d0000000-0000-0000-0000-00000000d0e2', 'Evento Schema 2', 'evento-schema-2', current_date, 'd0000000-0000-0000-0000-00000000d001');

-- ---------------------------------------------------------------
-- profiles_full_name_not_blank
-- ---------------------------------------------------------------
select throws_ok(
  $$ update public.profiles set full_name = '' where id = 'd0000000-0000-0000-0000-00000000d001' $$,
  '23514',
  null,
  'full_name vazio é rejeitado'
);

select throws_ok(
  $$ update public.profiles set full_name = '   ' where id = 'd0000000-0000-0000-0000-00000000d001' $$,
  '23514',
  null,
  'full_name só com espaço é rejeitado (btrim)'
);

-- ---------------------------------------------------------------
-- sessions_event_id_name_key — unique (event_id, lower(btrim(name)))
-- ---------------------------------------------------------------
select lives_ok(
  $$ insert into public.sessions (event_id, name, created_by)
     values ('d0000000-0000-0000-0000-00000000d0e1', 'Culto da manhã', 'd0000000-0000-0000-0000-00000000d001') $$,
  'primeira sessão do evento é aceita'
);

select throws_ok(
  $$ insert into public.sessions (event_id, name, created_by)
     values ('d0000000-0000-0000-0000-00000000d0e1', 'Culto da manhã', 'd0000000-0000-0000-0000-00000000d001') $$,
  '23505',
  null,
  'sessão com nome idêntico no mesmo evento é rejeitada'
);

select throws_ok(
  $$ insert into public.sessions (event_id, name, created_by)
     values ('d0000000-0000-0000-0000-00000000d0e1', '  CULTO DA MANHÃ  ', 'd0000000-0000-0000-0000-00000000d001') $$,
  '23505',
  null,
  'sessão com mesmo nome em capitalização/espaço diferente é rejeitada'
);

select lives_ok(
  $$ insert into public.sessions (event_id, name, created_by)
     values ('d0000000-0000-0000-0000-00000000d0e2', 'Culto da manhã', 'd0000000-0000-0000-0000-00000000d001') $$,
  'mesmo nome em evento diferente é aceito — a unicidade é por evento'
);

-- ---------------------------------------------------------------
-- events_created_by_idx
-- ---------------------------------------------------------------
select has_index(
  'public'::name, 'events'::name, 'events_created_by_idx'::name,
  'events.created_by tem índice de apoio para a FK on delete restrict'
);

select * from finish();
rollback;
