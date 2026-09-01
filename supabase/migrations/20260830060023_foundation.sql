-- Fase 1 — Fundação (docs/ARQUITETURA.md §13)
-- profiles, events, sessions + RLS. Nada de fotos, menores ou faces ainda.

create type user_role as enum ('admin', 'uploader', 'member');

create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  avatar_key text,
  role       user_role not null default 'member',
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table events (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null unique,
  description text,
  cover_key   text,
  event_date  date not null,
  created_by  uuid not null references profiles(id) on delete restrict,
  created_at  timestamptz not null default now()
);
create index on events (event_date desc);

create table sessions (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references events(id) on delete cascade,
  name       text not null,
  position   int not null default 0,
  created_at timestamptz not null default now()
);
create index on sessions (event_id, position);

-- ---------------------------------------------------------------
-- Funções auxiliares de RLS (docs/ARQUITETURA.md §5.1)
-- ---------------------------------------------------------------
create or replace function my_role()
returns user_role language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and is_active;
$$;

create or replace function is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select my_role() = 'admin';
$$;

create or replace function can_upload()
returns boolean language sql stable security definer set search_path = public as $$
  select my_role() in ('admin','uploader');
$$;

-- ---------------------------------------------------------------
-- RLS (docs/ARQUITETURA.md §5.2)
-- ---------------------------------------------------------------
alter table profiles enable row level security;
alter table events   enable row level security;
alter table sessions enable row level security;

create policy "read profiles" on profiles
  for select using (auth.uid() is not null);
create policy "update own profile" on profiles
  for update using (id = auth.uid())
  with check (id = auth.uid() and role = my_role() and is_active);
create policy "admin manages profiles" on profiles
  for all using (is_admin()) with check (is_admin());

create policy "read events" on events for select using (auth.uid() is not null);
create policy "create events" on events
  for insert with check (can_upload() and created_by = auth.uid());
create policy "update events" on events
  for update using (is_admin() or created_by = auth.uid())
  with check (is_admin() or created_by = auth.uid());
create policy "delete events" on events for delete using (is_admin());

create policy "read sessions" on sessions for select using (auth.uid() is not null);
create policy "create sessions" on sessions for insert with check (can_upload());
create policy "update sessions" on sessions
  for update using (can_upload()) with check (can_upload());
create policy "delete sessions" on sessions for delete using (is_admin());
