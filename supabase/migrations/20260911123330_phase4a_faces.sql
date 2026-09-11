-- Fase 4a — Faces: face_consents, photo_grants, search_faces
-- (docs/ARQUITETURA.md §13, §5.4; docs/adr/0009)
-- photo_faces já existe desde a fase 2 (ADR 0004) com as duas primeiras
-- travas da regra "menor nunca é indexado" (CLAUDE.md §3). Esta migration
-- acrescenta a terceira: o filtro de contains_minors dentro de search_faces.
-- Ordem: tabelas → rls → policies → função → índices → grants/revokes.

-- ---------------------------------------------------------------
-- face_consents (docs/ARQUITETURA.md §4) — consentimento do próprio
-- adulto para uso de dados faciais. Dado pessoal sensível (CLAUDE.md §5.2).
-- ---------------------------------------------------------------
create table face_consents (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  granted_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  terms_version text not null
);

-- ---------------------------------------------------------------
-- photo_grants (docs/ARQUITETURA.md §4) — acesso permanente a foto privada
-- de adulto, concedido como efeito colateral de search_faces. Só search_
-- faces escreve (security definer); o cliente nunca insere/atualiza.
--
-- Revogabilidade (docs/adr/0009): grant já emitido é permanente na leitura
-- — revogar face_consents bloqueia buscas NOVAS, não apaga grants
-- existentes (mesmo raciocínio da ADR 0005 para minor_consents: revogação
-- não pode punir quem revogou). A única forma de desfazer um grant é
-- admin remover a linha — válvula de escape para falso positivo do
-- algoritmo, que ainda não foi calibrado (ARQUITETURA.md §7).
-- ---------------------------------------------------------------
create table photo_grants (
  user_id    uuid not null references profiles(id) on delete cascade,
  photo_id   uuid not null references photos(id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (user_id, photo_id)
);

-- ---------------------------------------------------------------
-- RLS habilitada em toda tabela nova (CLAUDE.md §5.1)
-- ---------------------------------------------------------------
alter table face_consents enable row level security;
alter table photo_grants  enable row level security;

-- ---------------------------------------------------------------
-- Policies — face_consents: só o próprio titular (ou admin) lê/grava o
-- próprio consentimento.
-- ---------------------------------------------------------------
create policy "read own consent" on face_consents
  for select to authenticated
  using ((select is_admin())
         or ((select is_member()) and user_id = (select auth.uid())));
create policy "grant own consent" on face_consents
  for insert to authenticated
  with check ((select is_member()) and user_id = (select auth.uid()));
create policy "revoke own consent" on face_consents
  for update to authenticated
  using ((select is_member()) and user_id = (select auth.uid()));

-- ---------------------------------------------------------------
-- Policies — photo_grants: leitura do próprio grant (ou admin). Sem
-- policy de insert/update — só search_faces grava, como security definer.
-- Delete só admin: válvula de escape de falso positivo (ADR 0009).
-- ---------------------------------------------------------------
create policy "read own grants" on photo_grants
  for select to authenticated
  using ((select is_admin())
         or ((select is_member()) and user_id = (select auth.uid())));
create policy "admin removes grants" on photo_grants
  for delete to authenticated using ((select is_admin()));

-- ---------------------------------------------------------------
-- read photos: versão final (fase 4, docs/adr/0005 e 0009). Troca só o
-- ramo de is_private para incluir photo_grants — o ramo de contains_minors
-- não é tocado, já ficou pronto na fase 3.
-- ---------------------------------------------------------------
drop policy "read photos" on photos;
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
      or (
        coalesce(contains_minors, true) = false
        and (
          not is_private
          or exists (select 1 from photo_grants g
                      where g.photo_id = photos.id
                        and g.user_id = (select auth.uid())))
      )
      or (coalesce(contains_minors, true) = true and is_guardian_of_photo(id))
    )
  );

-- ---------------------------------------------------------------
-- search_faces (docs/ARQUITETURA.md §5.4) — terceira camada da regra
-- "menor nunca é indexado" (CLAUDE.md §3): mesmo que algo escape das duas
-- primeiras (worker, trigger em photo_faces), esta função nunca retorna
-- foto marcada.
--
-- Nota de implementação (docs/adr/0009): ARQUITETURA.md §5.4 descreve a
-- busca via `create temp table _hits on commit drop`, mas isso só dropa a
-- tabela no commit da transação — uma segunda chamada na mesma transação
-- (pgTAP, ou qualquer sessão que não faça autocommit por statement) falha
-- com "relation _hits already exists". Uma CTE que grava (INSERT ...
-- RETURNING) e lê no mesmo statement produz o mesmo resultado, atômico,
-- sem depender de estado de sessão entre chamadas. `pg_temp` no
-- search_path segue obrigatório mesmo sem tabela temporária própria: é
-- `security definer`, e omitir `pg_temp` deixaria uma tabela temporária do
-- chamador ser pesquisada antes de `public` na resolução de nomes.
-- ---------------------------------------------------------------
create or replace function search_faces(
  p_embedding vector(512),
  p_event_id  uuid default null,
  p_threshold real default 0.38,
  p_limit     int  default 200
)
returns table (photo_id uuid, distance real)
language plpgsql volatile
security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
begin
  -- perfil ativo, não apenas autenticado
  if not is_member() then
    raise exception 'perfil inativo ou nao autenticado';
  end if;

  if not exists (select 1 from face_consents
                  where user_id = v_user and revoked_at is null) then
    raise exception 'consentimento de uso de dados faciais não registrado';
  end if;

  if (select count(*) from access_logs
       where user_id = v_user and action = 'face_search'
         and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'muitas buscas seguidas; tente novamente mais tarde';
  end if;

  insert into access_logs (user_id, action) values (v_user, 'face_search');

  return query
  with hits as (
    select f.photo_id as pid, min(f.embedding <=> p_embedding)::real as dist
    from photo_faces f
    join photos p on p.id = f.photo_id
    where p.deleted_at is null
      and coalesce(p.contains_minors, true) = false   -- terceira trava
      and (p_event_id is null or f.event_id = p_event_id)
      and (f.embedding <=> p_embedding) < p_threshold
    group by f.photo_id
    order by dist
    limit p_limit
  ),
  grant_ins as (
    insert into photo_grants (user_id, photo_id)
    select v_user, h.pid from hits h
    join photos p on p.id = h.pid
    where p.is_private
    on conflict do nothing
    returning 1
  )
  select h.pid, h.dist from hits h order by h.dist;
end;
$$;

revoke execute on function search_faces from public;
grant execute on function search_faces to authenticated;

-- ---------------------------------------------------------------
-- Índices
-- Consulta de consentimento ativo em search_faces filtra por user_id com
-- revoked_at is null a cada chamada.
-- ---------------------------------------------------------------
create index face_consents_active_idx on face_consents (user_id) where revoked_at is null;

-- ---------------------------------------------------------------
-- Grants/revokes
-- ---------------------------------------------------------------
revoke all on face_consents from anon;
revoke delete on face_consents from authenticated;

revoke all on photo_grants from anon;
revoke insert, update on photo_grants from authenticated;
