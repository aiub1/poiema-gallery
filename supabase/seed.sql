-- seed.sql — minimal development data.
-- Applied by `npx supabase db reset` after every migration.
--
-- Keep it small: a couple of profiles (one per role, plus one desativado),
-- one event, one session.
-- Never seed real people, real photos, or anything resembling a face embedding.
--
-- auth.users aciona trg_on_auth_user_created (docs/adr/0003), que já cria a
-- linha em public.profiles como member/inativo. Por isso ajustamos com
-- `update`, não `insert` — e o `update` só passa porque este script roda
-- como `postgres`, isento em enforce_profile_privileged_columns (ADR 0003).

insert into auth.users (
  instance_id, id, aud, role, email,
  encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '11111111-1111-1111-1111-111111111111',
   'authenticated', 'authenticated', 'admin@poiema.test',
   crypt('devpassword', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '22222222-2222-2222-2222-222222222222',
   'authenticated', 'authenticated', 'uploader@poiema.test',
   crypt('devpassword', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '33333333-3333-3333-3333-333333333333',
   'authenticated', 'authenticated', 'membro@poiema.test',
   crypt('devpassword', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444441',
   'authenticated', 'authenticated', 'desativado@poiema.test',
   crypt('devpassword', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}', '{}', now(), now());

update public.profiles set full_name = 'Admin da Igreja', role = 'admin', is_active = true
  where id = '11111111-1111-1111-1111-111111111111';
update public.profiles set full_name = 'Fotógrafo Voluntário', role = 'uploader', is_active = true
  where id = '22222222-2222-2222-2222-222222222222';
update public.profiles set full_name = 'Membro Qualquer', role = 'member', is_active = true
  where id = '33333333-3333-3333-3333-333333333333';
-- fixture do cenário de perfil inativo: nasce member/inativo e fica assim.
update public.profiles set full_name = 'Conta Desativada'
  where id = '44444444-4444-4444-4444-444444444441';

insert into public.events (id, name, slug, event_date, created_by) values
  ('44444444-4444-4444-4444-444444444444', 'Culto 23/08/2026', 'culto-2026-08-23',
   '2026-08-23', '11111111-1111-1111-1111-111111111111');

insert into public.sessions (event_id, name, position, created_by) values
  ('44444444-4444-4444-4444-444444444444', 'Culto da manhã', 0,
   '11111111-1111-1111-1111-111111111111');

-- Fase 2: fotos do uploader seed, uma para cada valor de contains_minors —
-- cobre os três casos que a policy de leitura trata de forma diferente.
insert into public.photos (
  id, event_id, session_id, uploaded_by,
  storage_key, web_key, thumb_key,
  contains_minors, status
) values
  ('55555555-5555-5555-5555-555555555551', '44444444-4444-4444-4444-444444444444',
   null, '22222222-2222-2222-2222-222222222222',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555551/original.webp',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555551/web.webp',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555551/thumb.webp',
   false, 'indexed'),
  ('55555555-5555-5555-5555-555555555552', '44444444-4444-4444-4444-444444444444',
   null, '22222222-2222-2222-2222-222222222222',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555552/original.webp',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555552/web.webp',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555552/thumb.webp',
   true, 'skipped'),
  ('55555555-5555-5555-5555-555555555553', '44444444-4444-4444-4444-444444444444',
   null, '22222222-2222-2222-2222-222222222222',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555553/original.webp',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555553/web.webp',
   'events/44444444-4444-4444-4444-444444444444/photos/55555555-5555-5555-5555-555555555553/thumb.webp',
   null, 'pending_review');

insert into public.removal_requests (photo_id, requested_by, reason) values
  ('55555555-5555-5555-5555-555555555551', '22222222-2222-2222-2222-222222222222',
   'foto duplicada, subida por engano');

insert into public.jobs (type, payload) values
  ('index_faces', jsonb_build_object('photo_id', '55555555-5555-5555-5555-555555555551'));

-- Fase 3: um menor, vínculo com o membro seed, consentimento registrado, e
-- a marcação ligando o menor à foto que já tem contains_minors = true.
insert into public.minors (id, full_name, birth_date, created_by) values
  ('66666666-6666-6666-6666-666666666661', 'Menor de Teste', '2020-01-01',
   '11111111-1111-1111-1111-111111111111');

insert into public.guardians (guardian_id, minor_id, relation, created_by) values
  ('33333333-3333-3333-3333-333333333333', '66666666-6666-6666-6666-666666666661',
   'mãe', '11111111-1111-1111-1111-111111111111');

insert into public.minor_consents (minor_id, guardian_id, terms_version) values
  ('66666666-6666-6666-6666-666666666661', '33333333-3333-3333-3333-333333333333',
   '2026-08-v1');

insert into public.photo_minors (photo_id, minor_id, tagged_by) values
  ('55555555-5555-5555-5555-555555555552', '66666666-6666-6666-6666-666666666661',
   '22222222-2222-2222-2222-222222222222');

-- Fase 4a: consentimento facial ativo do membro seed, e embedding sintético
-- só na foto que pode ser indexada (contains_minors = false). A foto
-- '...552' tem contains_minors = true — nenhum embedding entra nela; se o
-- trigger deixasse, seria bug do trigger (CLAUDE.md §3).
insert into public.face_consents (user_id, terms_version) values
  ('33333333-3333-3333-3333-333333333333', '2026-08-v1');

insert into public.photo_faces (photo_id, event_id, embedding) values
  ('55555555-5555-5555-5555-555555555551', '44444444-4444-4444-4444-444444444444',
   array_fill(0.1, array[512])::vector);
