-- pgTAP — Fase 4a: face_consents, photo_grants, search_faces
-- (docs/ARQUITETURA.md §5.4, docs/adr/0009). Cenários obrigatórios:
-- CLAUDE.md §8. Os testes de 00/02/03 continuam rodando contra a policy
-- nova de "read photos" sem alteração — regressão, não repetida aqui.

begin;

create extension if not exists pgtap;

select plan(14);

-- ---------------------------------------------------------------
-- fixtures: profiles próprias deste arquivo, sem depender de seed.sql
-- ---------------------------------------------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a001', 'authenticated', 'authenticated', 'test-faces-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a002', 'authenticated', 'authenticated', 'test-faces-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a003', 'authenticated', 'authenticated', 'test-faces-member-ok@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a004', 'authenticated', 'authenticated', 'test-faces-member-no-consent@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a005', 'authenticated', 'authenticated', 'test-faces-member-revoked@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a006', 'authenticated', 'authenticated', 'test-faces-member-inactive@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'aa000000-0000-0000-0000-00000000a007', 'authenticated', 'authenticated', 'test-faces-member-rate-limited@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Admin Faces',              role = 'admin',    is_active = true where id = 'aa000000-0000-0000-0000-00000000a001';
update public.profiles set full_name = 'Uploader Faces',           role = 'uploader', is_active = true where id = 'aa000000-0000-0000-0000-00000000a002';
update public.profiles set full_name = 'Membro Com Consentimento',  role = 'member',   is_active = true where id = 'aa000000-0000-0000-0000-00000000a003';
update public.profiles set full_name = 'Membro Sem Consentimento',  role = 'member',   is_active = true where id = 'aa000000-0000-0000-0000-00000000a004';
update public.profiles set full_name = 'Membro Consentimento Revogado', role = 'member', is_active = true where id = 'aa000000-0000-0000-0000-00000000a005';
-- a006 fica member/inativo, valor de nascença do trigger de provisionamento.
update public.profiles set full_name = 'Membro Limite de Buscas',   role = 'member',   is_active = true where id = 'aa000000-0000-0000-0000-00000000a007';

insert into public.events (id, name, slug, event_date, created_by) values
  ('aa000000-0000-0000-0000-00000000b001', 'Evento Faces', 'evento-faces', current_date, 'aa000000-0000-0000-0000-00000000a001');

-- fotos: pública/indexada, privada/indexada, menor/indexada (embedding
-- forçado abaixo), e uma que será soft-deletada depois de indexada
insert into public.photos (id, event_id, uploaded_by, storage_key, web_key, thumb_key, contains_minors, is_private, status) values
  ('aa000000-0000-0000-0000-00000000d001', 'aa000000-0000-0000-0000-00000000b001', 'aa000000-0000-0000-0000-00000000a002', 'fd1o', 'fd1w', 'fd1t', false, false, 'indexed'),
  ('aa000000-0000-0000-0000-00000000d002', 'aa000000-0000-0000-0000-00000000b001', 'aa000000-0000-0000-0000-00000000a002', 'fd2o', 'fd2w', 'fd2t', false, true,  'indexed'),
  ('aa000000-0000-0000-0000-00000000d003', 'aa000000-0000-0000-0000-00000000b001', 'aa000000-0000-0000-0000-00000000a002', 'fd3o', 'fd3w', 'fd3t', true,  false, 'indexed'),
  ('aa000000-0000-0000-0000-00000000d004', 'aa000000-0000-0000-0000-00000000b001', 'aa000000-0000-0000-0000-00000000a002', 'fd4o', 'fd4w', 'fd4t', false, false, 'indexed');

-- embeddings idênticos ao vetor de busca (distância cosseno 0) nas fotos
-- que podem ser indexadas de verdade
insert into public.photo_faces (photo_id, event_id, embedding) values
  ('aa000000-0000-0000-0000-00000000d001', 'aa000000-0000-0000-0000-00000000b001', array_fill(0.1, array[512])::vector),
  ('aa000000-0000-0000-0000-00000000d002', 'aa000000-0000-0000-0000-00000000b001', array_fill(0.1, array[512])::vector),
  ('aa000000-0000-0000-0000-00000000d004', 'aa000000-0000-0000-0000-00000000b001', array_fill(0.1, array[512])::vector);

-- fd004 vira soft-deletada depois de já indexada — search_faces filtra
-- p.deleted_at is null, então some do resultado sem precisar apagar o
-- embedding (trigger de purga só reage a contains_minors, não a deleted_at)
update public.photos set deleted_at = now() where id = 'aa000000-0000-0000-0000-00000000d004';

-- fd003 (menor): as duas primeiras travas (CLAUDE.md §3) não deixam um
-- embedding legítimo entrar aqui em circunstância alguma — nem o trigger de
-- insert nem o de purga podem ser contornados por um caminho normal de SQL.
-- Para testar a TERCEIRA trava (o filtro dentro de search_faces) isolada
-- das outras duas, como pedido na etapa 1, desligamos o trigger de insert
-- só dentro desta transação de teste (que sofre rollback ao final) para
-- simular o cenário "algo escapou das duas primeiras camadas".
alter table public.photo_faces disable trigger trg_forbid_minor_faces;
insert into public.photo_faces (photo_id, event_id, embedding) values
  ('aa000000-0000-0000-0000-00000000d003', 'aa000000-0000-0000-0000-00000000b001', array_fill(0.1, array[512])::vector);
alter table public.photo_faces enable trigger trg_forbid_minor_faces;

-- consentimentos
insert into public.face_consents (user_id, terms_version) values
  ('aa000000-0000-0000-0000-00000000a003', '2026-08-v1'),
  ('aa000000-0000-0000-0000-00000000a007', '2026-08-v1');
insert into public.face_consents (user_id, terms_version, revoked_at) values
  ('aa000000-0000-0000-0000-00000000a005', '2026-08-v1', now());
-- a004 (sem consentimento): nenhuma linha.

-- 20 buscas já registradas na última hora para o membro do teste de limite
insert into public.access_logs (user_id, action, created_at)
select 'aa000000-0000-0000-0000-00000000a007', 'face_search', now()
from generate_series(1, 20);

-- ---------------------------------------------------------------
-- guardas de acesso a search_faces
-- ---------------------------------------------------------------
set local role authenticated;

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a006","role":"authenticated"}';
select throws_ok(
  $$ select * from search_faces(array_fill(0.1, array[512])::vector) $$,
  'P0001', 'perfil inativo ou nao autenticado',
  'perfil inativo não executa search_faces'
);

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a004","role":"authenticated"}';
select throws_ok(
  $$ select * from search_faces(array_fill(0.1, array[512])::vector) $$,
  'P0001', 'consentimento de uso de dados faciais não registrado',
  'sem consentimento não executa search_faces'
);

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a005","role":"authenticated"}';
select throws_ok(
  $$ select * from search_faces(array_fill(0.1, array[512])::vector) $$,
  'P0001', 'consentimento de uso de dados faciais não registrado',
  'consentimento revogado não executa search_faces'
);

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a007","role":"authenticated"}';
select throws_ok(
  $$ select * from search_faces(array_fill(0.1, array[512])::vector) $$,
  'P0001', 'muitas buscas seguidas; tente novamente mais tarde',
  'rate limit dispara na 21a busca'
);

-- ---------------------------------------------------------------
-- membro com consentimento ativo: busca de verdade
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a003","role":"authenticated"}';

select is(
  (select count(*)::int from search_faces(array_fill(0.1, array[512])::vector) x where x.photo_id = 'aa000000-0000-0000-0000-00000000d001'),
  1,
  'busca encontra foto pública indexada (controle positivo)'
);

select is(
  (select count(*)::int from search_faces(array_fill(0.1, array[512])::vector) x where x.photo_id = 'aa000000-0000-0000-0000-00000000d002'),
  1,
  'busca encontra foto privada indexada (concede grant)'
);

select is(
  (select count(*)::int from search_faces(array_fill(0.1, array[512])::vector) x where x.photo_id = 'aa000000-0000-0000-0000-00000000d003'),
  0,
  'busca nunca retorna foto com contains_minors = true, mesmo com embedding plantado à força'
);

select is(
  (select count(*)::int from search_faces(array_fill(0.1, array[512])::vector) x where x.photo_id = 'aa000000-0000-0000-0000-00000000d004'),
  0,
  'busca nunca retorna foto soft-deletada'
);

select is(
  (select count(*)::int from public.photo_grants
    where user_id = 'aa000000-0000-0000-0000-00000000a003'
      and photo_id = 'aa000000-0000-0000-0000-00000000d002'),
  1,
  'search_faces grava photo_grants para a foto privada encontrada'
);

select is(
  (select count(*)::int from public.photos where id = 'aa000000-0000-0000-0000-00000000d002'),
  1,
  'grant emitido libera a leitura da foto privada em read photos'
);

-- ---------------------------------------------------------------
-- remoção de grant: válvula de escape de falso positivo (docs/adr/0009)
-- só admin remove; member e uploader não conseguem, mesmo o próprio titular
-- ---------------------------------------------------------------
select is_empty(
  $$ delete from public.photo_grants
      where user_id = 'aa000000-0000-0000-0000-00000000a003'
        and photo_id = 'aa000000-0000-0000-0000-00000000d002'
     returning 1 $$,
  'member (mesmo titular do grant) não remove photo_grants'
);

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a002","role":"authenticated"}';
select is_empty(
  $$ delete from public.photo_grants
      where user_id = 'aa000000-0000-0000-0000-00000000a003'
        and photo_id = 'aa000000-0000-0000-0000-00000000d002'
     returning 1 $$,
  'uploader não remove photo_grants'
);

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a001","role":"authenticated"}';
select lives_ok(
  $$ delete from public.photo_grants
      where user_id = 'aa000000-0000-0000-0000-00000000a003'
        and photo_id = 'aa000000-0000-0000-0000-00000000d002' $$,
  'admin remove photo_grants'
);

set local request.jwt.claims to '{"sub":"aa000000-0000-0000-0000-00000000a003","role":"authenticated"}';
select is(
  (select count(*)::int from public.photos where id = 'aa000000-0000-0000-0000-00000000d002'),
  0,
  'depois do admin remover o grant, a foto privada volta a ficar invisível'
);

select * from finish();
rollback;
