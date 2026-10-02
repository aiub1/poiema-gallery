-- pgTAP — Evento público (migration 0007, docs/adr/0014).
-- O que precisa continuar verdade: anon só enxerga, pelas funções public_*,
-- foto de evento is_public que seja sem menores (respondido), não privada,
-- publicada e não excluída. E anon segue sem ler tabela nenhuma.

begin;

create extension if not exists pgtap;

select plan(22);

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'a7000000-0000-0000-0000-00000000a001', 'authenticated', 'authenticated', 'test-public-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'a7000000-0000-0000-0000-00000000a002', 'authenticated', 'authenticated', 'test-public-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Admin Público',    role = 'admin',    is_active = true where id = 'a7000000-0000-0000-0000-00000000a001';
update public.profiles set full_name = 'Uploader Público', role = 'uploader', is_active = true where id = 'a7000000-0000-0000-0000-00000000a002';

insert into public.events (id, name, slug, event_date, created_by, is_public) values
  ('b7000000-0000-0000-0000-00000000b001', 'Aberto',   'aberto',   current_date, 'a7000000-0000-0000-0000-00000000a001', true),
  ('b7000000-0000-0000-0000-00000000b002', 'Fechado',  'fechado',  current_date, 'a7000000-0000-0000-0000-00000000a001', false),
  ('b7000000-0000-0000-0000-00000000b003', 'Excluído', 'excluido', current_date, 'a7000000-0000-0000-0000-00000000a001', true),
  ('b7000000-0000-0000-0000-00000000b004', 'Do uploader', 'do-uploader', current_date, 'a7000000-0000-0000-0000-00000000a002', false);
update public.events set deleted_at = now() where id = 'b7000000-0000-0000-0000-00000000b003';

insert into public.sessions (id, event_id, name, position, created_by) values
  ('c7000000-0000-0000-0000-00000000c001', 'b7000000-0000-0000-0000-00000000b001', 'Sessão I',  0, 'a7000000-0000-0000-0000-00000000a001'),
  ('c7000000-0000-0000-0000-00000000c002', 'b7000000-0000-0000-0000-00000000b001', 'Sessão II', 1, 'a7000000-0000-0000-0000-00000000a001');

insert into public.photos (id, event_id, session_id, uploaded_by, storage_key, web_key, thumb_key, contains_minors, is_private, status) values
  -- evento aberto
  ('d7000000-0000-0000-0000-00000000d001', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o1', 'w1', 't1', false, false, 'skipped'),        -- pública
  ('d7000000-0000-0000-0000-00000000d002', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c002', 'a7000000-0000-0000-0000-00000000a001', 'o2', 'w2', 't2', false, false, 'indexed'),        -- pública
  ('d7000000-0000-0000-0000-00000000d003', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o3', 'w3', 't3', true,  false, 'skipped'),        -- menores
  ('d7000000-0000-0000-0000-00000000d004', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o4', 'w4', 't4', null,  false, 'pending_review'), -- não respondida
  ('d7000000-0000-0000-0000-00000000d005', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o5', 'w5', 't5', false, true,  'indexed'),        -- privada
  ('d7000000-0000-0000-0000-00000000d006', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o6', 'w6', 't6', false, false, 'pending_review'), -- em revisão
  ('d7000000-0000-0000-0000-00000000d007', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o7', 'w7', 't7', false, false, 'indexed'),        -- excluída (abaixo)
  ('d7000000-0000-0000-0000-00000000d008', 'b7000000-0000-0000-0000-00000000b001', 'c7000000-0000-0000-0000-00000000c001', 'a7000000-0000-0000-0000-00000000a001', 'o8', 'w8', 't8', null,  false, 'indexed'),        -- nulo com status publicado
  -- evento fechado e evento excluído: fotos que seriam públicas
  ('d7000000-0000-0000-0000-00000000d009', 'b7000000-0000-0000-0000-00000000b002', null, 'a7000000-0000-0000-0000-00000000a001', 'o9', 'w9', 't9', false, false, 'indexed'),
  ('d7000000-0000-0000-0000-00000000d010', 'b7000000-0000-0000-0000-00000000b003', null, 'a7000000-0000-0000-0000-00000000a001', 'o10', 'w10', 't10', false, false, 'indexed');
update public.photos set deleted_at = now() where id = 'd7000000-0000-0000-0000-00000000d007';

-- ---------------------------------------------------------------
-- anon
-- ---------------------------------------------------------------
set local role anon;
set local request.jwt.claims to '{"role":"anon"}';

select throws_ok(
  $$ select 1 from public.photos $$, '42501', null,
  'anon continua sem ler a tabela photos'
);
select throws_ok(
  $$ select 1 from public.events $$, '42501', null,
  'anon continua sem ler a tabela events'
);
select throws_ok(
  $$ select 1 from public.sessions $$, '42501', null,
  'anon continua sem ler a tabela sessions'
);
select throws_ok(
  $$ select 1 from public.public_photos_of('b7000000-0000-0000-0000-00000000b001') $$, '42501', null,
  'anon não executa a função interna public_photos_of'
);

select is((select count(*)::int from public.public_event('aberto')), 1, 'anon lê evento público');
select is((select count(*)::int from public.public_event('fechado')), 0, 'anon não lê evento não público');
select is((select count(*)::int from public.public_event('excluido')), 0, 'anon não lê evento público excluído');
select is((select photo_count::int from public.public_event('aberto')), 2, 'contagem do evento só conta fotos públicas');

select results_eq(
  $$ select id from public.public_event_photos('aberto') order by id $$,
  $$ values ('d7000000-0000-0000-0000-00000000d001'::uuid), ('d7000000-0000-0000-0000-00000000d002'::uuid) $$,
  'anon vê só fotos sem menores, não privadas, publicadas e não excluídas'
);
select is(
  (select count(*)::int from public.public_event_photos('aberto') where id = 'd7000000-0000-0000-0000-00000000d003'),
  0, 'foto com contains_minors = true nunca é pública'
);
select is(
  (select count(*)::int from public.public_event_photos('aberto') where id = 'd7000000-0000-0000-0000-00000000d008'),
  0, 'foto com contains_minors nulo nunca é pública, mesmo com status publicado'
);
select is((select count(*)::int from public.public_event_photos('fechado')), 0, 'anon não lista fotos de evento não público');
select is((select count(*)::int from public.public_event_photos('excluido')), 0, 'anon não lista fotos de evento excluído');
select is(
  (select count(*)::int from public.public_event_photos('aberto', 'c7000000-0000-0000-0000-00000000c002')),
  1, 'filtro por sessão'
);
select is((select count(*)::int from public.public_event_photos('aberto', null, 100000, 0)), 2, 'p_limit acima do teto não quebra');

select results_eq(
  $$ select name, photo_count::int from public.public_event_sessions('aberto') $$,
  $$ values ('Sessão I', 1), ('Sessão II', 1) $$,
  'sessões em ordem, com contagem só das fotos públicas'
);

select is((select web_key from public.public_photo('d7000000-0000-0000-0000-00000000d001')), 'w1', 'public_photo devolve foto pública');
select is((select count(*)::int from public.public_photo('d7000000-0000-0000-0000-00000000d003')), 0, 'public_photo não devolve foto com menores');
select is((select count(*)::int from public.public_photo('d7000000-0000-0000-0000-00000000d009')), 0, 'public_photo não devolve foto de evento fechado');

-- ---------------------------------------------------------------
-- is_public só muda por admin
-- ---------------------------------------------------------------
reset role;
set local role authenticated;
set local request.jwt.claims to '{"sub":"a7000000-0000-0000-0000-00000000a002","role":"authenticated"}';

select throws_ok(
  $$ update public.events set is_public = true where id = 'b7000000-0000-0000-0000-00000000b004' $$,
  '42501', null,
  'uploader não abre o próprio evento ao público'
);
select throws_ok(
  $$ insert into public.events (name, slug, event_date, created_by, is_public)
     values ('Novo', 'novo-publico', current_date, 'a7000000-0000-0000-0000-00000000a002', true) $$,
  '42501', null,
  'uploader não cria evento já público'
);

set local request.jwt.claims to '{"sub":"a7000000-0000-0000-0000-00000000a001","role":"authenticated"}';
select lives_ok(
  $$ update public.events set is_public = true where id = 'b7000000-0000-0000-0000-00000000b002' $$,
  'admin abre evento ao público'
);

select * from finish();
rollback;
