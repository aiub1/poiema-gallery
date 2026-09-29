-- Fase 1 — Fundação (docs/ARQUITETURA.md §13)
-- profiles, events, sessions + RLS. Nada de fotos, menores ou faces ainda.
-- Ordem obrigatória (docs/adr/0002-migration-conventions.md):
--   profiles → funções auxiliares → enable rls → policies → grants → demais tabelas

create type user_role as enum ('admin', 'uploader', 'member');

create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  avatar_key text,
  role       user_role not null default 'member',
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
create index profiles_role_idx on profiles (role) where is_active;

-- ---------------------------------------------------------------
-- Funções auxiliares de RLS (docs/ARQUITETURA.md §5.1)
-- ---------------------------------------------------------------
create or replace function my_role()
returns user_role language sql stable
security definer set search_path = public, pg_temp as $$
  select role from profiles where id = auth.uid() and is_active;
$$;

-- Perfil ativo. Base de TODA policy de leitura do schema.
create or replace function is_member()
returns boolean language sql stable
security definer set search_path = public, pg_temp as $$
  select my_role() is not null;
$$;

create or replace function is_admin()
returns boolean language sql stable
security definer set search_path = public, pg_temp as $$
  select coalesce(my_role() = 'admin', false);
$$;

create or replace function can_upload()
returns boolean language sql stable
security definer set search_path = public, pg_temp as $$
  select coalesce(my_role() in ('admin','uploader'), false);
$$;

revoke execute on function my_role, is_member, is_admin, can_upload from public;
grant execute on function my_role, is_member, is_admin, can_upload to authenticated, service_role;

-- ---------------------------------------------------------------
-- RLS de profiles (docs/ARQUITETURA.md §5.2)
-- ---------------------------------------------------------------
alter table profiles enable row level security;

-- Cada um lê o próprio registro mesmo inativo: a UI precisa da linha para
-- mostrar "conta aguardando ativação" em vez de uma tela vazia.
create policy "read profiles" on profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select is_member()));
create policy "update own profile" on profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));
create policy "admin inserts profiles" on profiles
  for insert to authenticated with check ((select is_admin()));
create policy "admin updates profiles" on profiles
  for update to authenticated
  using ((select is_admin())) with check ((select is_admin()));
-- sem policy de delete, nem para admin
revoke all on profiles from anon;
revoke delete on profiles from authenticated;

-- ---------------------------------------------------------------
-- Triggers de proteção de profiles (docs/ARQUITETURA.md §5.3)
-- ---------------------------------------------------------------

-- Congela role, is_active, id e created_at para quem não é admin.
-- Security invoker de propósito: dentro de uma função security definer,
-- current_user resolveria para o dono e a checagem de papel seria letra morta.
create or replace function enforce_profile_privileged_columns()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  -- bootstrap do primeiro admin e seed rodam como postgres (ADR 0003)
  if current_user in ('postgres','supabase_admin','service_role') then
    return new;
  end if;
  if is_admin() then
    return new;
  end if;
  if new.role      is distinct from old.role
     or new.is_active  is distinct from old.is_active
     or new.id         is distinct from old.id
     or new.created_at is distinct from old.created_at then
    raise exception 'coluna privilegiada de perfil so muda por admin'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger trg_profiles_privileged_columns
  before update on profiles
  for each row execute function enforce_profile_privileged_columns();

-- Provisiona o perfil a partir de auth.users, sempre INATIVO (ADR 0003).
create or replace function handle_new_auth_user()
returns trigger language plpgsql
security definer set search_path = public, pg_temp as $$
begin
  insert into public.profiles (id, full_name, role, is_active)
  values (
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
             'Novo membro'),
    'member',
    false            -- ⚠️ nasce INATIVO. Ver ADR 0003 antes de mudar.
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

revoke execute on function handle_new_auth_user from public;
grant execute on function handle_new_auth_user to supabase_auth_admin;

-- ---------------------------------------------------------------
-- events (docs/ARQUITETURA.md §4)
-- ---------------------------------------------------------------
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
create index events_event_date_idx on events (event_date desc);

-- ---------------------------------------------------------------
-- sessions (docs/ARQUITETURA.md §4)
-- ---------------------------------------------------------------
create table sessions (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null references events(id) on delete cascade,
  name       text not null,
  position   int not null default 0,
  created_by uuid not null references profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index sessions_event_id_position_idx on sessions (event_id, position);

-- ---------------------------------------------------------------
-- RLS de events / sessions (docs/ARQUITETURA.md §5.2)
-- ---------------------------------------------------------------
alter table events   enable row level security;
alter table sessions enable row level security;

create policy "read events" on events
  for select to authenticated using ((select is_member()));
create policy "create events" on events
  for insert to authenticated
  with check ((select can_upload()) and created_by = (select auth.uid()));
create policy "update events" on events
  for update to authenticated
  using ((select is_admin()) or created_by = (select auth.uid()))
  with check ((select is_admin()) or created_by = (select auth.uid()));
create policy "delete events" on events
  for delete to authenticated using ((select is_admin()));

create policy "read sessions" on sessions
  for select to authenticated using ((select is_member()));
create policy "create sessions" on sessions
  for insert to authenticated
  with check ((select can_upload()) and created_by = (select auth.uid()));
create policy "update sessions" on sessions
  for update to authenticated
  using ((select is_admin()) or created_by = (select auth.uid()))
  with check ((select is_admin()) or created_by = (select auth.uid()));
create policy "delete sessions" on sessions
  for delete to authenticated using ((select is_admin()));

-- Sistema fechado (CLAUDE.md §1): anon não tem privilégio em tabela alguma.
-- `to authenticated` já barra o anônimo, mas depende de toda policy futura
-- ser escrita corretamente; o revoke não depende de ninguém.
revoke all on events   from anon;
revoke all on sessions from anon;
