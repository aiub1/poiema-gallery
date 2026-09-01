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
