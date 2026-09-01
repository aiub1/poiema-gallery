-- pgTAP — Fase 1: RLS de profiles, events, sessions.
-- Um cenário por papel (docs/supabase/README.md). Roda dentro de `npx supabase test db`.

begin;

create extension if not exists pgtap;

select plan(15);

-- fixtures: um profile por papel, sem depender de seed.sql
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a001', 'authenticated', 'authenticated', 'test-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a002', 'authenticated', 'authenticated', 'test-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a003', 'authenticated', 'authenticated', 'test-member@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

insert into public.profiles (id, full_name, role) values
  ('a0000000-0000-0000-0000-00000000a001', 'Admin de Teste', 'admin'),
  ('a0000000-0000-0000-0000-00000000a002', 'Uploader de Teste', 'uploader'),
  ('a0000000-0000-0000-0000-00000000a003', 'Membro de Teste', 'member');

-- ---------------------------------------------------------------
-- admin: pode criar evento, criar sessão, e ver tudo
-- ---------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims to '{"sub":"a0000000-0000-0000-0000-00000000a001","role":"authenticated"}';

select lives_ok(
  $$ insert into public.events (id, name, slug, event_date, created_by)
     values ('e0000000-0000-0000-0000-00000000e001', 'Evento Admin', 'evento-admin', current_date, 'a0000000-0000-0000-0000-00000000a001') $$,
  'admin cria evento'
);

select lives_ok(
  $$ insert into public.sessions (event_id, name) values ('e0000000-0000-0000-0000-00000000e001', 'Sessão Admin') $$,
  'admin cria sessão'
);

select isnt_empty(
  $$ select 1 from public.profiles $$,
  'admin lê todos os profiles'
);

-- ---------------------------------------------------------------
-- uploader: pode criar evento e sessão, mas não apagar evento
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"a0000000-0000-0000-0000-00000000a002","role":"authenticated"}';

select lives_ok(
  $$ insert into public.events (id, name, slug, event_date, created_by)
     values ('e0000000-0000-0000-0000-00000000e002', 'Evento Uploader', 'evento-uploader', current_date, 'a0000000-0000-0000-0000-00000000a002') $$,
  'uploader cria evento'
);

select lives_ok(
  $$ insert into public.sessions (event_id, name) values ('e0000000-0000-0000-0000-00000000e002', 'Sessão Uploader') $$,
  'uploader cria sessão'
);

select is_empty(
  $$ delete from public.events where id = 'e0000000-0000-0000-0000-00000000e002' returning 1 $$,
  'uploader não apaga evento (nem o próprio)'
);

select throws_ok(
  $$ insert into public.events (id, name, slug, event_date, created_by)
     values ('e0000000-0000-0000-0000-00000000e003', 'Evento Falso', 'evento-falso', current_date, 'a0000000-0000-0000-0000-00000000a001') $$,
  '42501',
  null,
  'uploader não cria evento em nome de outro usuário'
);

-- ---------------------------------------------------------------
-- member: só lê, nunca escreve
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"a0000000-0000-0000-0000-00000000a003","role":"authenticated"}';

select isnt_empty(
  $$ select 1 from public.events $$,
  'member lê eventos'
);

select isnt_empty(
  $$ select 1 from public.sessions $$,
  'member lê sessões'
);

select throws_ok(
  $$ insert into public.events (id, name, slug, event_date, created_by)
     values ('e0000000-0000-0000-0000-00000000e004', 'Evento Member', 'evento-member', current_date, 'a0000000-0000-0000-0000-00000000a003') $$,
  '42501',
  null,
  'member não cria evento'
);

select throws_ok(
  $$ insert into public.sessions (event_id, name) values ('e0000000-0000-0000-0000-00000000e001', 'Sessão Member') $$,
  '42501',
  null,
  'member não cria sessão'
);

select throws_ok(
  $$ update public.profiles set role = 'admin' where id = 'a0000000-0000-0000-0000-00000000a003' $$,
  '42501',
  null,
  'member não promove o próprio papel'
);

-- ---------------------------------------------------------------
-- sem autenticação: nada é visível
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"role":"anon"}';
set local role anon;

select is_empty(
  $$ select 1 from public.events $$,
  'anon não lê eventos'
);

select is_empty(
  $$ select 1 from public.profiles $$,
  'anon não lê profiles'
);

select is_empty(
  $$ select 1 from public.sessions $$,
  'anon não lê sessões'
);

select * from finish();
rollback;
