-- pgTAP — role worker_service (docs/adr/0011-worker-service-role.md).
-- Sem bypassrls, RLS filtraria as leituras deste role; com bypassrls, RLS
-- não participa nada — só os grants de tabela e os triggers de
-- photo_faces protegem. Este arquivo prova as duas coisas: os três grants
-- funcionam, e nada além deles.

begin;

create extension if not exists pgtap;

select plan(25);

-- ---------------------------------------------------------------
-- fixtures: criadas como postgres, antes de trocar de role — worker_service
-- não tem grant para inserir em photos/jobs
-- ---------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'ee000000-0000-0000-0000-00000000e001', 'authenticated', 'authenticated', 'test-worker-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Uploader Worker', role = 'uploader', is_active = true where id = 'ee000000-0000-0000-0000-00000000e001';

insert into public.events (id, name, slug, event_date, created_by) values
  ('ee000000-0000-0000-0000-00000000b001', 'Evento Worker', 'evento-worker', current_date, 'ee000000-0000-0000-0000-00000000e001');

insert into public.photos (id, event_id, uploaded_by, storage_key, web_key, thumb_key, contains_minors, status) values
  ('ee000000-0000-0000-0000-00000000f001', 'ee000000-0000-0000-0000-00000000b001', 'ee000000-0000-0000-0000-00000000e001', 'w1o', 'w1w', 'w1t', false, 'pending'),
  ('ee000000-0000-0000-0000-00000000f002', 'ee000000-0000-0000-0000-00000000b001', 'ee000000-0000-0000-0000-00000000e001', 'w2o', 'w2w', 'w2t', true,  'pending'),
  ('ee000000-0000-0000-0000-00000000f003', 'ee000000-0000-0000-0000-00000000b001', 'ee000000-0000-0000-0000-00000000e001', 'w3o', 'w3w', 'w3t', null,  'pending');

insert into public.jobs (id, type, payload, status) values
  (900001, 'index_faces', jsonb_build_object('photo_id', 'ee000000-0000-0000-0000-00000000f001'), 'queued');

-- ---------------------------------------------------------------
-- controles positivos: os três grants da ADR 0011 funcionam
-- ---------------------------------------------------------------
set local role worker_service;

select is(
  (select count(*)::int from public.photos where id = 'ee000000-0000-0000-0000-00000000f001'),
  1,
  'worker_service lê photos (grant select)'
);

select lives_ok(
  $$ update public.photos set status = 'indexing' where id = 'ee000000-0000-0000-0000-00000000f001' $$,
  'worker_service atualiza photos (grant update)'
);

select is(
  (select count(*)::int from public.jobs where id = 900001),
  1,
  'worker_service lê jobs (grant select)'
);

select lives_ok(
  $$ update public.jobs set status = 'processing' where id = 900001 $$,
  'worker_service atualiza jobs (grant update)'
);

select lives_ok(
  $$ insert into public.photo_faces (photo_id, event_id, embedding)
     values ('ee000000-0000-0000-0000-00000000f001', 'ee000000-0000-0000-0000-00000000b001', array_fill(0::real, array[512])::vector) $$,
  'worker_service insere em photo_faces de foto sem menores (grant insert)'
);

-- ---------------------------------------------------------------
-- photo_faces: só insert. Sem update, sem delete — bug no worker não
-- sobrescreve nem apaga embedding já gravado.
-- ---------------------------------------------------------------
select throws_ok(
  $$ update public.photo_faces set quality = 0.9 where photo_id = 'ee000000-0000-0000-0000-00000000f001' $$,
  '42501',
  null,
  'worker_service NÃO atualiza photo_faces (sem grant update)'
);

select throws_ok(
  $$ delete from public.photo_faces where photo_id = 'ee000000-0000-0000-0000-00000000f001' $$,
  '42501',
  null,
  'worker_service NÃO apaga photo_faces (sem grant delete)'
);

-- ---------------------------------------------------------------
-- trg_forbid_minor_faces continua valendo para worker_service: bypassrls
-- desliga RLS, não trigger. Insert tem grant (acima), mas o CONTEÚDO
-- continua barrado pela mesma trava que vale para qualquer role.
-- ---------------------------------------------------------------
select throws_ok(
  $$ insert into public.photo_faces (photo_id, event_id, embedding)
     values ('ee000000-0000-0000-0000-00000000f002', 'ee000000-0000-0000-0000-00000000b001', array_fill(0::real, array[512])::vector) $$,
  'P0001',
  'proibido indexar rosto em foto marcada com menores',
  'worker_service: trg_forbid_minor_faces bloqueia foto com contains_minors = true'
);

select throws_ok(
  $$ insert into public.photo_faces (photo_id, event_id, embedding)
     values ('ee000000-0000-0000-0000-00000000f003', 'ee000000-0000-0000-0000-00000000b001', array_fill(0::real, array[512])::vector) $$,
  'P0001',
  'proibido indexar rosto em foto marcada com menores',
  'worker_service: trg_forbid_minor_faces bloqueia foto com contains_minors = null'
);

-- ---------------------------------------------------------------
-- tabelas inteiras fora do alcance: nem select, nem update. Sem
-- bypassrls contando como segunda camada aqui — é só o grant que falta.
-- ---------------------------------------------------------------
select throws_ok(
  $$ select count(*) from public.profiles $$, '42501', null,
  'worker_service NÃO lê profiles'
);
select throws_ok(
  $$ update public.profiles set role = 'admin' where false $$, '42501', null,
  'worker_service NÃO escreve profiles (nem role, invariante 8/9 do CONTRATO.md)'
);

select throws_ok(
  $$ select count(*) from public.guardians $$, '42501', null,
  'worker_service NÃO lê guardians'
);
select throws_ok(
  $$ update public.guardians set relation = 'x' where false $$, '42501', null,
  'worker_service NÃO escreve guardians'
);

select throws_ok(
  $$ select count(*) from public.minors $$, '42501', null,
  'worker_service NÃO lê minors'
);
select throws_ok(
  $$ update public.minors set full_name = 'x' where false $$, '42501', null,
  'worker_service NÃO escreve minors'
);

select throws_ok(
  $$ select count(*) from public.minor_consents $$, '42501', null,
  'worker_service NÃO lê minor_consents'
);
select throws_ok(
  $$ update public.minor_consents set revoked_at = now() where false $$, '42501', null,
  'worker_service NÃO escreve minor_consents'
);

select throws_ok(
  $$ select count(*) from public.face_consents $$, '42501', null,
  'worker_service NÃO lê face_consents'
);
select throws_ok(
  $$ update public.face_consents set revoked_at = now() where false $$, '42501', null,
  'worker_service NÃO escreve face_consents'
);

select throws_ok(
  $$ select count(*) from public.photo_grants $$, '42501', null,
  'worker_service NÃO lê photo_grants'
);
select throws_ok(
  $$ update public.photo_grants set granted_at = now() where false $$, '42501', null,
  'worker_service NÃO escreve photo_grants'
);

select throws_ok(
  $$ select count(*) from public.access_logs $$, '42501', null,
  'worker_service NÃO lê access_logs'
);
select throws_ok(
  $$ update public.access_logs set action = 'x' where false $$, '42501', null,
  'worker_service NÃO escreve access_logs'
);

select throws_ok(
  $$ select count(*) from public.removal_requests $$, '42501', null,
  'worker_service NÃO lê removal_requests'
);
select throws_ok(
  $$ update public.removal_requests set status = 'x' where false $$, '42501', null,
  'worker_service NÃO escreve removal_requests'
);

reset role;

select * from finish();
rollback;
