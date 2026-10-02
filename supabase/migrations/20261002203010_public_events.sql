-- 0007 — Evento público (docs/adr/0014-public-events.md, docs/CONTRATO.md §9)
--
-- Primeira leitura sem login do sistema: um evento marcado `is_public` pode
-- ter as fotos vistas e baixadas por qualquer pessoa (ex.: GetUp 2026).
--
-- O papel `anon` CONTINUA sem privilégio em tabela alguma (CLAUDE.md §1,
-- guarda em tests/010_schema_guards.sql). A leitura pública passa só por
-- quatro funções `security definer`, que devolvem colunas escolhidas a dedo e
-- aplicam a regra de visibilidade aqui, no banco — a web segue sem decidir
-- quem vê o quê (CONTRATO §1).
--
-- Regra pública, num lugar só (`public_photos_of`):
--   evento is_public e não excluído
--   foto não excluída, status <> 'pending_review'
--   contains_minors = false  (nulo ou true NUNCA é público — CLAUDE.md §3)
--   is_private = false
--
-- Ordem (docs/adr/0002): coluna → trigger → funções → grants/revokes.

-- ---------------------------------------------------------------
-- events.is_public
-- ---------------------------------------------------------------
alter table events add column is_public boolean not null default false;

-- Só admin liga ou desliga. A policy "update events" deixa o criador do
-- evento (um uploader) editar a própria linha; sem este trigger ele poderia
-- abrir um evento ao público sozinho.
-- Security invoker de propósito, como enforce_profile_privileged_columns:
-- dentro de security definer, current_user seria o dono da função.
create or replace function enforce_event_public_flag()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if current_user in ('postgres','supabase_admin','service_role') then
    return new;
  end if;
  if is_admin() then
    return new;
  end if;
  if (tg_op = 'INSERT' and new.is_public)
     or (tg_op = 'UPDATE' and new.is_public is distinct from old.is_public) then
    raise exception 'is_public de evento so muda por admin'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger trg_events_public_flag
  before insert or update on events
  for each row execute function enforce_event_public_flag();

-- ---------------------------------------------------------------
-- Regra de visibilidade pública — única definição, uso interno.
-- Security invoker e sem grant a anon/authenticated: só roda de dentro das
-- funções security definer abaixo.
-- ---------------------------------------------------------------
create or replace function public_photos_of(p_event_id uuid)
returns setof photos language sql stable
set search_path = public, pg_temp as $$
  select p.*
    from photos p
    join events e on e.id = p.event_id
   where e.id = p_event_id
     and e.is_public
     and e.deleted_at is null
     and p.deleted_at is null
     and p.status <> 'pending_review'
     and p.contains_minors is false
     and not p.is_private;
$$;

-- ---------------------------------------------------------------
-- Funções públicas (anon). Colunas devolvidas: só o necessário para a
-- página. Nunca storage_key (original), uploaded_by, status ou flags.
-- ---------------------------------------------------------------
create or replace function public_event(p_slug text)
returns table (
  id          uuid,
  name        text,
  slug        text,
  description text,
  event_date  date,
  cover_key   text,
  photo_count bigint
) language sql stable
security definer set search_path = public, pg_temp as $$
  select e.id, e.name, e.slug, e.description, e.event_date, e.cover_key,
         (select count(*) from public_photos_of(e.id))
    from events e
   where e.slug = p_slug and e.is_public and e.deleted_at is null;
$$;

create or replace function public_event_sessions(p_slug text)
returns table (
  id          uuid,
  name        text,
  "position"  int,
  photo_count bigint
) language sql stable
security definer set search_path = public, pg_temp as $$
  select s.id, s.name, s.position,
         (select count(*) from public_photos_of(e.id) p where p.session_id = s.id)
    from events e
    join sessions s on s.event_id = e.id
   where e.slug = p_slug and e.is_public and e.deleted_at is null
   order by s.position, s.created_at;
$$;

-- Mesma ordem da galeria da web: cronológica, sem taken_at no fim,
-- desempate por created_at e id. p_limit é limitado a 100 por chamada.
create or replace function public_event_photos(
  p_slug       text,
  p_session_id uuid default null,
  p_limit      int  default 48,
  p_offset     int  default 0
)
returns table (
  id         uuid,
  session_id uuid,
  thumb_key  text,
  web_key    text,
  width      int,
  height     int,
  taken_at   timestamptz
) language sql stable
security definer set search_path = public, pg_temp as $$
  select p.id, p.session_id, p.thumb_key, p.web_key, p.width, p.height, p.taken_at
    from events e
    cross join lateral public_photos_of(e.id) p
   where e.slug = p_slug
     and (p_session_id is null or p.session_id = p_session_id)
   order by p.taken_at asc nulls last, p.created_at asc, p.id asc
   limit least(greatest(coalesce(p_limit, 48), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
$$;

-- Uma foto pública pelo id (download). Devolve vazio para qualquer foto
-- que não passe na regra pública — a web não distingue "não existe" de
-- "não é pública".
create or replace function public_photo(p_id uuid)
returns table (
  id           uuid,
  web_key      text,
  thumb_key    text,
  event_slug   text,
  session_name text
) language sql stable
security definer set search_path = public, pg_temp as $$
  select p.id, p.web_key, p.thumb_key, e.slug, s.name
    from photos ph
    join events e on e.id = ph.event_id
    cross join lateral public_photos_of(e.id) p
    left join sessions s on s.id = p.session_id
   where ph.id = p_id and p.id = ph.id;
$$;

-- ---------------------------------------------------------------
-- Grants. O Supabase concede execute a anon/authenticated por default
-- privileges em toda função nova de public; por isso os revokes citam os
-- papéis pelo nome, não só `public`.
-- ---------------------------------------------------------------
revoke execute on function enforce_event_public_flag() from public, anon, authenticated;
revoke execute on function public_photos_of(uuid)      from public, anon, authenticated;

revoke execute on function public_event(text)                        from public;
revoke execute on function public_event_sessions(text)               from public;
revoke execute on function public_event_photos(text, uuid, int, int) from public;
revoke execute on function public_photo(uuid)                        from public;

grant execute on function public_event(text)                        to anon, authenticated, service_role;
grant execute on function public_event_sessions(text)               to anon, authenticated, service_role;
grant execute on function public_event_photos(text, uuid, int, int) to anon, authenticated, service_role;
grant execute on function public_photo(uuid)                        to anon, authenticated, service_role;
