-- pgTAP — Fase 2: RLS de photos, photo_faces, removal_requests, jobs, e o
-- soft delete de events (docs/adr/0004). Cenários obrigatórios: CLAUDE.md §8.

begin;

create extension if not exists pgtap;

select plan(23);

-- fixtures: profiles próprias deste arquivo, sem depender de seed.sql
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000c001', 'authenticated', 'authenticated', 'test-photos-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000c002', 'authenticated', 'authenticated', 'test-photos-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000c003', 'authenticated', 'authenticated', 'test-photos-member@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-0000-0000-00000000c004', 'authenticated', 'authenticated', 'test-photos-inactive@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Admin Fotos',    role = 'admin',    is_active = true where id = 'c0000000-0000-0000-0000-00000000c001';
update public.profiles set full_name = 'Uploader Fotos', role = 'uploader', is_active = true where id = 'c0000000-0000-0000-0000-00000000c002';
update public.profiles set full_name = 'Membro Fotos',   role = 'member',   is_active = true where id = 'c0000000-0000-0000-0000-00000000c003';
-- c004 fica member/inativo, valor de nascença do trigger de provisionamento.

insert into public.events (id, name, slug, event_date, created_by) values
  ('d0000000-0000-0000-0000-00000000d001', 'Evento Fotos', 'evento-fotos', current_date, 'c0000000-0000-0000-0000-00000000c001');

-- fotos: uma para cada regra de visibilidade que a policy "read photos" trata
insert into public.photos (id, event_id, uploaded_by, storage_key, web_key, thumb_key, contains_minors, is_private, status) values
  ('f0000000-0000-0000-0000-00000000f001', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k1o', 'k1w', 'k1t', false, false, 'indexed'),  -- pública, controle positivo
  ('f0000000-0000-0000-0000-00000000f002', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k2o', 'k2w', 'k2t', true,  false, 'indexed'),  -- menor
  ('f0000000-0000-0000-0000-00000000f003', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k3o', 'k3w', 'k3t', false, true,  'indexed'),  -- privada, sem grant
  ('f0000000-0000-0000-0000-00000000f004', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k4o', 'k4w', 'k4t', false, false, 'pending_review'),
  ('f0000000-0000-0000-0000-00000000f005', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k5o', 'k5w', 'k5t', false, false, 'indexed');
update public.photos set deleted_at = now() where id = 'f0000000-0000-0000-0000-00000000f005';

-- fotos para os cenários de photo_faces (trigas rodam como postgres, sem
-- depender de grant — as duas travas de banco não podem ser contornadas
-- nem pelo dono da tabela; CLAUDE.md §3)
insert into public.photos (id, event_id, uploaded_by, storage_key, web_key, thumb_key, contains_minors, status) values
  ('f0000000-0000-0000-0000-00000000f006', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k6o', 'k6w', 'k6t', false, 'indexed'),
  ('f0000000-0000-0000-0000-00000000f007', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k7o', 'k7w', 'k7t', true,  'indexed'),
  ('f0000000-0000-0000-0000-00000000f008', 'd0000000-0000-0000-0000-00000000d001', 'c0000000-0000-0000-0000-00000000c002', 'k8o', 'k8w', 'k8t', null,  'pending_review');

-- ---------------------------------------------------------------
-- member: regra central de visibilidade de photos
-- ---------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims to '{"sub":"c0000000-0000-0000-0000-00000000c003","role":"authenticated"}';

select is(
  (select count(*)::int from public.photos where id = 'f0000000-0000-0000-0000-00000000f001'),
  1,
  'member lê foto pública indexada (controle positivo)'
);

select is(
  (select count(*)::int from public.photos where id = 'f0000000-0000-0000-0000-00000000f002'),
  0,
  'member não lê foto com contains_minors = true de menor não vinculada'
);

select is(
  (select count(*)::int from public.photos where id = 'f0000000-0000-0000-0000-00000000f003'),
  0,
  'member não lê foto privada sem grant'
);

select is(
  (select count(*)::int from public.photos where id = 'f0000000-0000-0000-0000-00000000f004'),
  0,
  'member não lê foto com status pending_review'
);

select is(
  (select count(*)::int from public.photos where id = 'f0000000-0000-0000-0000-00000000f005'),
  0,
  'member não lê foto com deleted_at not null'
);

select throws_ok(
  $$ insert into public.jobs (type, payload) values ('index_faces', '{}'::jsonb) $$,
  '42501',
  null,
  'member não insere em jobs diretamente'
);

select throws_ok(
  $$ insert into public.removal_requests (photo_id, requested_by)
     values ('f0000000-0000-0000-0000-00000000f001', 'c0000000-0000-0000-0000-00000000c003') $$,
  '42501',
  null,
  'member não abre removal_request'
);

-- ---------------------------------------------------------------
-- uploader: dono da foto, mas não admin
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"c0000000-0000-0000-0000-00000000c002","role":"authenticated"}';

select is_empty(
  $$ delete from public.photos where id = 'f0000000-0000-0000-0000-00000000f001' returning 1 $$,
  'uploader não consegue DELETE em foto, nem a própria'
);

select lives_ok(
  $$ insert into public.removal_requests (photo_id, requested_by, reason)
     values ('f0000000-0000-0000-0000-00000000f002', 'c0000000-0000-0000-0000-00000000c002', 'pedido de remoção de teste') $$,
  'uploader abre removal_request'
);

select is_empty(
  $$ update public.removal_requests
       set status = 'approved', reviewed_by = 'c0000000-0000-0000-0000-00000000c002'
     where photo_id = 'f0000000-0000-0000-0000-00000000f002' returning 1 $$,
  'uploader não revisa removal_request'
);

-- ---------------------------------------------------------------
-- admin: DELETE em foto e revisão de removal_request
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"c0000000-0000-0000-0000-00000000c001","role":"authenticated"}';

select is(
  (select count(*)::int from public.photos where id = 'f0000000-0000-0000-0000-00000000f001'),
  1,
  'admin lê a foto antes de excluir (pré-condição)'
);

select lives_ok(
  $$ delete from public.photos where id = 'f0000000-0000-0000-0000-00000000f001' $$,
  'admin consegue DELETE em foto'
);

select lives_ok(
  $$ update public.removal_requests
       set status = 'approved', reviewed_by = 'c0000000-0000-0000-0000-00000000c001', reviewed_at = now()
     where photo_id = 'f0000000-0000-0000-0000-00000000f002' $$,
  'admin revisa removal_request'
);

-- soft delete de evento (docs/adr/0004): DELETE real fica revogado do papel
-- authenticated inteiro, mesmo para admin — "excluir" é update de deleted_at.
select throws_ok(
  $$ delete from public.events where id = 'd0000000-0000-0000-0000-00000000d001' $$,
  '42501',
  null,
  'admin não executa DELETE real em events — revogado, só soft delete'
);

-- events.deleted_at não é gravável nem por admin autenticado: a policy
-- "read events" filtra `deleted_at is null`, e o Postgres exige que a linha
-- resultante de um UPDATE sob RLS também passe pela policy de SELECT. Não é
-- uma lacuna — é o esperado: soft delete de evento só acontece por rota de
-- servidor com service_role (docs/adr/0004, CLAUDE.md §5.3), nunca pelo JWT
-- do cliente, admin incluído.
select throws_ok(
  $$ update public.events set deleted_at = now() where id = 'd0000000-0000-0000-0000-00000000d001' $$,
  '42501',
  null,
  'admin não soft-deleta evento pelo próprio JWT — só service_role grava deleted_at'
);

-- service_role bypassa RLS; simulado aqui como postgres (mesmo papel que
-- roda migrations/seed).
reset role;
update public.events set deleted_at = now() where id = 'd0000000-0000-0000-0000-00000000d001';

set local role authenticated;
set local request.jwt.claims to '{"sub":"c0000000-0000-0000-0000-00000000c003","role":"authenticated"}';

select is_empty(
  $$ select 1 from public.events where id = 'd0000000-0000-0000-0000-00000000d001' $$,
  'member não lê evento soft-deletado'
);

select is_empty(
  $$ select 1 from public.photos where event_id = 'd0000000-0000-0000-0000-00000000d001' $$,
  'member não lê fotos de evento soft-deletado'
);

-- ---------------------------------------------------------------
-- perfil inativo: nada além do próprio profiles
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"c0000000-0000-0000-0000-00000000c004","role":"authenticated"}';

select is_empty(
  $$ select 1 from public.photos $$,
  'perfil inativo não lê fotos'
);

-- ---------------------------------------------------------------
-- photo_faces: as duas travas de banco da regra "menor nunca é indexado"
-- (CLAUDE.md §3). Rodam sem troca de papel: nem o dono da tabela pode
-- contornar o trigger, e a inserção real só acontece via service_role
-- de qualquer forma (revoke all on photo_faces from anon, authenticated).
-- ---------------------------------------------------------------
reset role;

select throws_ok(
  $$ insert into public.photo_faces (photo_id, event_id, embedding)
     values ('f0000000-0000-0000-0000-00000000f007', 'd0000000-0000-0000-0000-00000000d001', array_fill(0::real, array[512])::vector) $$,
  'P0001',
  'proibido indexar rosto em foto marcada com menores',
  'INSERT em photo_faces de foto com contains_minors = true falha'
);

select throws_ok(
  $$ insert into public.photo_faces (photo_id, event_id, embedding)
     values ('f0000000-0000-0000-0000-00000000f008', 'd0000000-0000-0000-0000-00000000d001', array_fill(0::real, array[512])::vector) $$,
  'P0001',
  'proibido indexar rosto em foto marcada com menores',
  'INSERT em photo_faces de foto com contains_minors = null falha'
);

select lives_ok(
  $$ insert into public.photo_faces (photo_id, event_id, embedding)
     values ('f0000000-0000-0000-0000-00000000f006', 'd0000000-0000-0000-0000-00000000d001', array_fill(0::real, array[512])::vector) $$,
  'INSERT em photo_faces de foto sem menores funciona'
);

select is(
  (select count(*)::int from public.photo_faces where photo_id = 'f0000000-0000-0000-0000-00000000f006'),
  1,
  'embedding existe antes de marcar contains_minors'
);

update public.photos set contains_minors = true where id = 'f0000000-0000-0000-0000-00000000f006';

select is(
  (select count(*)::int from public.photo_faces where photo_id = 'f0000000-0000-0000-0000-00000000f006'),
  0,
  'marcar contains_minors = true em foto já indexada apaga os embeddings'
);

select * from finish();
rollback;
