-- pgTAP — Fase 3: RLS de minors, guardians, minor_consents, photo_minors, e
-- a versão intermediária de "read photos" (docs/adr/0005). Cenários
-- obrigatórios: CLAUDE.md §8. Os testes de 02_photos_rls.sql continuam
-- rodando contra a policy nova sem alteração — regressão, não repetida aqui.

begin;

create extension if not exists pgtap;

select plan(9);

-- fixtures: profiles próprias deste arquivo, sem depender de seed.sql
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', '90000000-0000-0000-0000-00000000a001', 'authenticated', 'authenticated', 'test-minors-admin@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '90000000-0000-0000-0000-00000000a002', 'authenticated', 'authenticated', 'test-minors-uploader@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '90000000-0000-0000-0000-00000000a003', 'authenticated', 'authenticated', 'test-minors-member@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '90000000-0000-0000-0000-00000000a004', 'authenticated', 'authenticated', 'test-minors-guardian@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '90000000-0000-0000-0000-00000000a005', 'authenticated', 'authenticated', 'test-minors-guardian-inactive@poiema.test', crypt('x', gen_salt('bf')), now(), '{}', '{}', now(), now());

update public.profiles set full_name = 'Admin Menores',     role = 'admin',    is_active = true where id = '90000000-0000-0000-0000-00000000a001';
update public.profiles set full_name = 'Uploader Menores',  role = 'uploader', is_active = true where id = '90000000-0000-0000-0000-00000000a002';
update public.profiles set full_name = 'Membro Não Vinculado', role = 'member', is_active = true where id = '90000000-0000-0000-0000-00000000a003';
update public.profiles set full_name = 'Responsável Ativo', role = 'member',   is_active = true where id = '90000000-0000-0000-0000-00000000a004';
-- a005 fica member/inativo, valor de nascença do trigger de provisionamento
-- — é exatamente a fixture do cenário "responsável inativo".

insert into public.events (id, name, slug, event_date, created_by) values
  ('90000000-0000-0000-0000-00000000b001', 'Evento Menores', 'evento-menores', current_date, '90000000-0000-0000-0000-00000000a001');

-- dois menores: um com responsável ativo, outro com responsável inativo
insert into public.minors (id, full_name, created_by) values
  ('90000000-0000-0000-0000-00000000c001', 'Menor Vinculado', '90000000-0000-0000-0000-00000000a001'),
  ('90000000-0000-0000-0000-00000000c002', 'Menor de Responsável Inativo', '90000000-0000-0000-0000-00000000a001');

insert into public.guardians (guardian_id, minor_id, relation, created_by) values
  ('90000000-0000-0000-0000-00000000a004', '90000000-0000-0000-0000-00000000c001', 'mãe', '90000000-0000-0000-0000-00000000a001'),
  ('90000000-0000-0000-0000-00000000a005', '90000000-0000-0000-0000-00000000c002', 'pai', '90000000-0000-0000-0000-00000000a001');

insert into public.minor_consents (minor_id, guardian_id, terms_version) values
  ('90000000-0000-0000-0000-00000000c001', '90000000-0000-0000-0000-00000000a004', '2026-08-v1');

-- fotos: 9d01 pública quanto a is_private, 9d02 privada — as duas com
-- contains_minors = true, para o teste de união das regras (ARQUITETURA.md
-- §2: is_private não bloqueia o responsável vinculado). 9d03 é do menor com
-- responsável inativo.
insert into public.photos (id, event_id, uploaded_by, storage_key, web_key, thumb_key, contains_minors, is_private, status) values
  ('90000000-0000-0000-0000-00000000d001', '90000000-0000-0000-0000-00000000b001', '90000000-0000-0000-0000-00000000a002', 'm1o', 'm1w', 'm1t', true, false, 'indexed'),
  ('90000000-0000-0000-0000-00000000d002', '90000000-0000-0000-0000-00000000b001', '90000000-0000-0000-0000-00000000a002', 'm2o', 'm2w', 'm2t', true, true,  'indexed'),
  ('90000000-0000-0000-0000-00000000d003', '90000000-0000-0000-0000-00000000b001', '90000000-0000-0000-0000-00000000a002', 'm3o', 'm3w', 'm3t', true, false, 'indexed');

insert into public.photo_minors (photo_id, minor_id, tagged_by) values
  ('90000000-0000-0000-0000-00000000d001', '90000000-0000-0000-0000-00000000c001', '90000000-0000-0000-0000-00000000a002'),
  ('90000000-0000-0000-0000-00000000d002', '90000000-0000-0000-0000-00000000c001', '90000000-0000-0000-0000-00000000a002'),
  ('90000000-0000-0000-0000-00000000d003', '90000000-0000-0000-0000-00000000c002', '90000000-0000-0000-0000-00000000a002');

-- ---------------------------------------------------------------
-- responsável vinculado ativo: lê a foto do filho, inclusive privada
-- (união das regras, ARQUITETURA.md §2 — is_private não gateia este ramo)
-- ---------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims to '{"sub":"90000000-0000-0000-0000-00000000a004","role":"authenticated"}';

select is(
  (select count(*)::int from public.photos where id = '90000000-0000-0000-0000-00000000d001'),
  1,
  'responsável vinculado ativo lê foto pública do filho'
);

select is(
  (select count(*)::int from public.photos where id = '90000000-0000-0000-0000-00000000d002'),
  1,
  'responsável vinculado ativo lê foto privada do filho (união das regras)'
);

select throws_ok(
  $$ insert into public.guardians (guardian_id, minor_id, created_by)
     values ('90000000-0000-0000-0000-00000000a004', '90000000-0000-0000-0000-00000000c002', '90000000-0000-0000-0000-00000000a004') $$,
  '42501',
  null,
  'responsável (member) não cria vínculo em guardians'
);

-- ---------------------------------------------------------------
-- member não vinculado: não vê a foto de menor que não é seu
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"90000000-0000-0000-0000-00000000a003","role":"authenticated"}';

select is(
  (select count(*)::int from public.photos where id = '90000000-0000-0000-0000-00000000d001'),
  0,
  'member não vinculado não lê foto de menor não vinculada a ele'
);

select throws_ok(
  $$ insert into public.minors (full_name, created_by)
     values ('Menor Falso', '90000000-0000-0000-0000-00000000a003') $$,
  '42501',
  null,
  'member não insere em minors'
);

-- ---------------------------------------------------------------
-- responsável inativo: nem a própria foto do filho vinculado
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"90000000-0000-0000-0000-00000000a005","role":"authenticated"}';

select is(
  (select count(*)::int from public.photos where id = '90000000-0000-0000-0000-00000000d003'),
  0,
  'responsável inativo não lê a foto do filho vinculado'
);

-- ---------------------------------------------------------------
-- uploader: marca foto com photo_minors, mas não cria vínculo em guardians
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"90000000-0000-0000-0000-00000000a002","role":"authenticated"}';

select lives_ok(
  $$ insert into public.photo_minors (photo_id, minor_id, tagged_by)
     values ('90000000-0000-0000-0000-00000000d003', '90000000-0000-0000-0000-00000000c001', '90000000-0000-0000-0000-00000000a002') $$,
  'uploader marca foto com photo_minors'
);

select throws_ok(
  $$ insert into public.guardians (guardian_id, minor_id, created_by)
     values ('90000000-0000-0000-0000-00000000a002', '90000000-0000-0000-0000-00000000c001', '90000000-0000-0000-0000-00000000a002') $$,
  '42501',
  null,
  'uploader não cria vínculo em guardians'
);

-- ---------------------------------------------------------------
-- admin: cria vínculo em guardians
-- ---------------------------------------------------------------
set local request.jwt.claims to '{"sub":"90000000-0000-0000-0000-00000000a001","role":"authenticated"}';

select lives_ok(
  $$ insert into public.guardians (guardian_id, minor_id, created_by)
     values ('90000000-0000-0000-0000-00000000a003', '90000000-0000-0000-0000-00000000c002', '90000000-0000-0000-0000-00000000a001') $$,
  'admin cria vínculo em guardians'
);

select * from finish();
rollback;
