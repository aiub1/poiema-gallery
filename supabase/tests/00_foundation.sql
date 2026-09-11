-- pgTAP — Fase 1: RLS de profiles, events, sessions.
-- Um cenário por papel (docs/supabase/README.md). Roda dentro de `npx supabase test db`.

begin;

create extension if not exists pgtap;

select plan(25);

-- fixtures: um profile por papel, sem depender de seed.sql
-- auth.users aciona trg_on_auth_user_created (docs/adr/0003): a linha em
-- public.profiles já nasce sozinha, member/inativa. Por isso ativamos e
-- promovemos com UPDATE, não INSERT — e isso só funciona porque este bloco
-- roda como `postgres`, isento em enforce_profile_privileged_columns.
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a001', 'authenticated', 'authenticated', 'test-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a002', 'authenticated', 'authenticated', 'test-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a003', 'authenticated', 'authenticated', 'test-member@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a004', 'authenticated', 'authenticated', 'test-inactive@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-0000-0000-00000000a005', 'authenticated', 'authenticated', 'test-uploader2@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Admin de Teste',      role = 'admin',    is_active = true where id = 'a0000000-0000-0000-0000-00000000a001';
update public.profiles set full_name = 'Uploader de Teste',   role = 'uploader', is_active = true where id = 'a0000000-0000-0000-0000-00000000a002';
update public.profiles set full_name = 'Membro de Teste',     role = 'member',   is_active = true where id = 'a0000000-0000-0000-0000-00000000a003';
update public.profiles set full_name = 'Uploader 2 de Teste', role = 'uploader', is_active = true where id = 'a0000000-0000-0000-0000-00000000a005';
-- a004 fica member/inativo — é exatamente o valor que o trigger dá sozinho,
-- por isso não tocamos em role/is_active dela: é a fixture do perfil inativo
-- E também a prova do cenário de provisionamento, checada abaixo.

-- ---------------------------------------------------------------
-- provisionamento: perfil nasce a partir de auth.users, member + inativo
-- ---------------------------------------------------------------
select is(
  (select role::text from public.profiles where id = 'a0000000-0000-0000-0000-00000000a004'),
  'member',
  'perfil provisionado a partir de auth.users nasce com papel member'
);

select is(
  (select is_active from public.profiles where id = 'a0000000-0000-0000-0000-00000000a004'),
  false,
  'perfil provisionado a partir de auth.users nasce inativo'
);

-- ---------------------------------------------------------------
-- admin: pode criar evento, criar sessão, ver tudo, mas não deleta profiles
-- ---------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims to '{"sub":"a0000000-0000-0000-0000-00000000a001","role":"authenticated"}';

select lives_ok(
  $$ insert into public.events (id, name, slug, event_date, created_by)
     values ('e0000000-0000-0000-0000-00000000e001', 'Evento Admin', 'evento-admin', current_date, 'a0000000-0000-0000-0000-00000000a001') $$,
  'admin cria evento'
);

select lives_ok(
  $$ insert into public.sessions (event_id, name, created_by)
     values ('e0000000-0000-0000-0000-00000000e001', 'Sessão Admin', 'a0000000-0000-0000-0000-00000000a001') $$,
  'admin cria sessão'
);

select isnt_empty(
  $$ select 1 from public.profiles $$,
  'admin lê todos os profiles'
);

select throws_ok(
  $$ delete from public.profiles where id = 'a0000000-0000-0000-0000-00000000a003' $$,
  '42501',
  null,
  'admin não executa delete em profiles'
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
  $$ insert into public.sessions (event_id, name, created_by)
     values ('e0000000-0000-0000-0000-00000000e002', 'Sessão Uploader', 'a0000000-0000-0000-0000-00000000a002') $$,
  'uploader cria sessão'
);

-- DELETE em events foi revogado de authenticated na fase 2 (docs/adr/0004):
-- "excluir" um evento passa a ser soft delete via update de deleted_at.
select throws_ok(
  $$ delete from public.events where id = 'e0000000-0000-0000-0000-00000000e002' returning 1 $$,
  '42501',
  null,
  'uploader não apaga evento (nem o próprio) — delete revogado, só soft delete'
);

select throws_ok(
  $$ insert into public.events (id, name, slug, event_date, created_by)
     values ('e0000000-0000-0000-0000-00000000e003', 'Evento Falso', 'evento-falso', current_date, 'a0000000-0000-0000-0000-00000000a001') $$,
  '42501',
  null,
  'uploader não cria evento em nome de outro usuário'
);

-- ---------------------------------------------------------------
-- member: só lê, nunca escreve, não se autopromove nem se reativa
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
  $$ insert into public.sessions (event_id, name, created_by)
     values ('e0000000-0000-0000-0000-00000000e001', 'Sessão Member', 'a0000000-0000-0000-0000-00000000a003') $$,
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

select throws_ok(
  $$ update public.profiles set is_active = false where id = 'a0000000-0000-0000-0000-00000000a003' $$,
  '42501',
  null,
  'member não altera o próprio is_active'
);

select throws_ok(
  $$ delete from public.profiles where id = 'a0000000-0000-0000-0000-00000000a003' $$,
  '42501',
  null,
  'member não executa delete em profiles'
);

-- ---------------------------------------------------------------
-- perfil inativo: só enxerga o próprio registro em profiles, nada mais
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"a0000000-0000-0000-0000-00000000a004","role":"authenticated"}';

select isnt_empty(
  $$ select 1 from public.profiles where id = 'a0000000-0000-0000-0000-00000000a004' $$,
  'perfil inativo lê o próprio registro em profiles'
);

select is_empty(
  $$ select 1 from public.profiles where id <> 'a0000000-0000-0000-0000-00000000a004' $$,
  'perfil inativo não lê outros profiles'
);

select is_empty(
  $$ select 1 from public.events $$,
  'perfil inativo não lê eventos'
);

select is_empty(
  $$ select 1 from public.sessions $$,
  'perfil inativo não lê sessões'
);

-- ---------------------------------------------------------------
-- uploader 2: mesmo papel, evento/sessão diferentes — não edita o alheio
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"a0000000-0000-0000-0000-00000000a005","role":"authenticated"}';

select is_empty(
  $$ update public.sessions set name = 'Sessão Sequestrada'
     where event_id = 'e0000000-0000-0000-0000-00000000e002' returning 1 $$,
  'uploader não edita sessão de evento alheio'
);

-- ---------------------------------------------------------------
-- sem autenticação: nada é visível. `revoke all ... from anon` (item 7)
-- barra no grant, antes de qualquer policy — erro de permissão, não RLS.
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"role":"anon"}';
set local role anon;

select throws_ok(
  $$ select 1 from public.events $$,
  '42501',
  null,
  'anon não lê eventos'
);

select throws_ok(
  $$ select 1 from public.profiles $$,
  '42501',
  null,
  'anon não lê profiles'
);

select throws_ok(
  $$ select 1 from public.sessions $$,
  '42501',
  null,
  'anon não lê sessões'
);

select * from finish();
rollback;
