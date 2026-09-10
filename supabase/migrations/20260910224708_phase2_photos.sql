-- Fase 2 — Fotos (docs/ARQUITETURA.md §13)
-- photos, photo_faces (antecipada — ver docs/adr/0004), removal_requests,
-- jobs, access_logs + soft delete em events (docs/adr/0004).
-- Nada de minors, guardians, minor_consents, face_consents, photo_grants
-- ainda — essas seguem para as fases 3 e 4.
-- Ordem (docs/adr/0002-migration-conventions.md): tabelas → rls → policies
-- → triggers → índices → grants/revokes.

-- ---------------------------------------------------------------
-- events: soft delete (docs/adr/0004) — fecha a pendência do
-- ARQUITETURA.md §15. DELETE real fica revogado; "excluir" um evento passa
-- a ser update de deleted_at, mesmo caminho já usado por profiles.
-- ---------------------------------------------------------------
alter table events add column deleted_at timestamptz;

drop policy "read events" on events;
create policy "read events" on events
  for select to authenticated
  using (deleted_at is null and (select is_member()));

revoke delete on events from authenticated;

-- ---------------------------------------------------------------
-- photos (docs/ARQUITETURA.md §4)
-- ---------------------------------------------------------------
create type photo_status as enum
  ('pending_review','pending','indexing','indexed','failed','skipped');

create table photos (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references events(id) on delete restrict,
  session_id      uuid references sessions(id) on delete set null,
  uploaded_by     uuid not null references profiles(id) on delete restrict,
  storage_key     text not null,
  web_key         text not null,
  thumb_key       text not null,
  width           int,
  height          int,
  bytes           int,
  taken_at        timestamptz,
  contains_minors boolean,      -- NULO = não respondido → não publica
  is_private      boolean not null default false,
  status          photo_status not null default 'pending_review',
  deleted_at      timestamptz,
  created_at      timestamptz not null default now()
);
create index on photos (event_id, created_at desc) where deleted_at is null;
create index on photos (session_id) where deleted_at is null;
create index on photos (status) where status in ('pending','failed','pending_review');

alter table photos enable row level security;

-- Regra central de visibilidade. Sem guardians/minors (fase 3) nem
-- photo_grants (fase 4) ainda: até lá, foto marcada com menor só é vista
-- por admin/uploader dono, e foto privada também — fail closed, coerente
-- com ARQUITETURA.md §5.2 aplicado ao que existe nesta fase.
create policy "read photos" on photos
  for select to authenticated using (
    deleted_at is null
    and status <> 'pending_review'
    and (select is_member())
    and exists (select 1 from events e
                 where e.id = photos.event_id and e.deleted_at is null)
    and (
      (select is_admin())
      or uploaded_by = (select auth.uid())
      or (coalesce(contains_minors, true) = false and not is_private)
    )
  );

create policy "insert photos" on photos
  for insert to authenticated
  with check ((select can_upload()) and uploaded_by = (select auth.uid()));
create policy "update own photo" on photos
  for update to authenticated
  using ((select is_admin()) or uploaded_by = (select auth.uid()))
  with check ((select is_admin()) or uploaded_by = (select auth.uid()));
create policy "delete photos" on photos
  for delete to authenticated using ((select is_admin()));

revoke all on photos from anon;

-- ---------------------------------------------------------------
-- photo_faces (docs/ARQUITETURA.md §4/§5.3) — antecipada da fase 4
-- (docs/adr/0004): as duas travas de banco da regra "menor nunca é
-- indexado" (CLAUDE.md §3) vivem nesta tabela e precisam existir antes de
-- qualquer foto entrar no banco, não quando o resto da fase 4 chegar.
-- ⚠️ SENSÍVEL — só adultos consentidos, nunca menores.
-- ---------------------------------------------------------------
create extension if not exists vector;

create table photo_faces (
  id         uuid primary key default gen_random_uuid(),
  photo_id   uuid not null references photos(id) on delete cascade,
  event_id   uuid not null references events(id) on delete cascade,
  embedding  vector(512) not null,
  bbox       jsonb,
  quality    real,
  created_at timestamptz not null default now()
);
create index on photo_faces (event_id);
create index photo_faces_embedding_idx on photo_faces
  using hnsw (embedding vector_cosine_ops);

alter table photo_faces enable row level security;

-- sem policy de select = ninguém lê (nem service_role via API de dados;
-- acesso só pela função search_faces, fase 4)
revoke all on photo_faces from anon, authenticated;

-- ---------------------------------------------------------------
-- Triggers de proteção de menores (docs/ARQUITETURA.md §5.3, CLAUDE.md §3)
-- Segunda e terceira camada — a primeira vive no worker (fase 4).
-- ---------------------------------------------------------------
create or replace function forbid_minor_faces()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if exists (select 1 from photos
              where id = new.photo_id
                and coalesce(contains_minors, true) = true) then
    raise exception 'proibido indexar rosto em foto marcada com menores';
  end if;
  return new;
end;
$$;

create trigger trg_forbid_minor_faces
  before insert on photo_faces
  for each row execute function forbid_minor_faces();

create or replace function purge_faces_on_minor_flag()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.contains_minors is true
     and coalesce(old.contains_minors, false) is false then
    delete from photo_faces where photo_id = new.id;
  end if;
  return new;
end;
$$;

create trigger trg_purge_faces_on_minor_flag
  after update of contains_minors on photos
  for each row execute function purge_faces_on_minor_flag();

-- ---------------------------------------------------------------
-- removal_requests (docs/ARQUITETURA.md §4)
-- ---------------------------------------------------------------
create table removal_requests (
  id           uuid primary key default gen_random_uuid(),
  photo_id     uuid not null references photos(id) on delete cascade,
  requested_by uuid not null references profiles(id) on delete cascade,
  reason       text,
  status       text not null default 'pending',
  reviewed_by  uuid references profiles(id),
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now()
);

alter table removal_requests enable row level security;

create policy "read own requests" on removal_requests
  for select to authenticated
  using ((select is_admin())
         or ((select is_member()) and requested_by = (select auth.uid())));
create policy "create request" on removal_requests
  for insert to authenticated
  with check ((select can_upload()) and requested_by = (select auth.uid()));
create policy "admin reviews" on removal_requests
  for update to authenticated
  using ((select is_admin())) with check ((select is_admin()));

revoke all on removal_requests from anon;

-- ---------------------------------------------------------------
-- jobs (docs/ARQUITETURA.md §4/§6, docs/CONTRATO.md §4)
-- Sem policy alguma: a web insere via rota de servidor com service_role,
-- o worker consome com service_role. Nenhum papel autenticado toca aqui.
-- ---------------------------------------------------------------
create table jobs (
  id         bigserial primary key,
  type       text not null,
  payload    jsonb not null,
  status     text not null default 'queued',
  attempts   int not null default 0,
  last_error text,
  locked_by  text,
  locked_at  timestamptz,
  run_after  timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index on jobs (status, run_after);

alter table jobs enable row level security;
revoke all on jobs from anon, authenticated;

-- ---------------------------------------------------------------
-- access_logs (docs/ARQUITETURA.md §4/§5.2)
-- Só a policy de leitura entra agora; o insert é feito por search_faces
-- (security definer, fase 4), que não precisa de policy própria.
-- ---------------------------------------------------------------
create table access_logs (
  id         bigserial primary key,
  user_id    uuid references profiles(id) on delete set null,
  action     text not null,
  target_id  uuid,
  created_at timestamptz not null default now()
);
create index on access_logs (user_id, created_at desc);

alter table access_logs enable row level security;

create policy "admin reads logs" on access_logs
  for select to authenticated using ((select is_admin()));

revoke all on access_logs from anon;
revoke insert, update, delete on access_logs from authenticated;
