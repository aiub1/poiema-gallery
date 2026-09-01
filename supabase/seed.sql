-- seed.sql — minimal development data.
-- Applied by `npx supabase db reset` after every migration.
--
-- Keep it small: a couple of profiles (one per role), one event, one session.
-- Never seed real people, real photos, or anything resembling a face embedding.

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
   '{"provider":"email","providers":["email"]}', '{}', now(), now());

insert into public.profiles (id, full_name, role) values
  ('11111111-1111-1111-1111-111111111111', 'Admin da Igreja', 'admin'),
  ('22222222-2222-2222-2222-222222222222', 'Fotógrafo Voluntário', 'uploader'),
  ('33333333-3333-3333-3333-333333333333', 'Membro Qualquer', 'member');

insert into public.events (id, name, slug, event_date, created_by) values
  ('44444444-4444-4444-4444-444444444444', 'Culto 23/08/2026', 'culto-2026-08-23',
   '2026-08-23', '11111111-1111-1111-1111-111111111111');

insert into public.sessions (event_id, name, position) values
  ('44444444-4444-4444-4444-444444444444', 'Culto da manhã', 0);
