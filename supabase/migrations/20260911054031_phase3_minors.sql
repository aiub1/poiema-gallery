-- Fase 3 — Menores (docs/ARQUITETURA.md §13)
-- minors, guardians, minor_consents, photo_minors + função is_guardian_of_photo
-- + substituição de "read photos" pela versão intermediária (docs/adr/0005).
-- Nada de face_consents, photo_grants nem search_faces ainda — fase 4.
-- Ordem (docs/adr/0002-migration-conventions.md): tabelas → rls → função
-- auxiliar → policies → índices → grants/revokes.

-- ---------------------------------------------------------------
-- minors: cadastro da secretaria, NÃO são usuários do sistema
-- (docs/ARQUITETURA.md §4)
-- ---------------------------------------------------------------
create table minors (
  id         uuid primary key default gen_random_uuid(),
  full_name  text not null,
  birth_date date,
  notes      text,
  created_by uuid not null references profiles(id) on delete restrict,
  created_at timestamptz not null default now()
);

create table guardians (
  guardian_id uuid not null references profiles(id) on delete cascade,
  minor_id    uuid not null references minors(id) on delete cascade,
  relation    text,
  created_by  uuid not null references profiles(id) on delete restrict,
  created_at  timestamptz not null default now(),
  primary key (guardian_id, minor_id)
);

create table minor_consents (
  id            uuid primary key default gen_random_uuid(),
  minor_id      uuid not null references minors(id) on delete cascade,
  guardian_id   uuid not null references profiles(id) on delete restrict,
  granted_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  terms_version text not null
);

create table photo_minors (
  photo_id   uuid not null references photos(id) on delete cascade,
  minor_id   uuid not null references minors(id) on delete cascade,
  tagged_by  uuid not null references profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (photo_id, minor_id)
);

-- ---------------------------------------------------------------
-- RLS habilitada em toda tabela nova (CLAUDE.md §5.1)
-- ---------------------------------------------------------------
alter table minors         enable row level security;
alter table guardians      enable row level security;
alter table minor_consents enable row level security;
alter table photo_minors   enable row level security;

-- ---------------------------------------------------------------
-- Função auxiliar (docs/ARQUITETURA.md §5.1)
-- security definer + pg_temp: sem isso, uma tabela temporária do chamador
-- poderia sequestrar a resolução de photo_minors/guardians dentro da
-- função, que roda com os privilégios do dono.
-- Chama is_member() internamente: um responsável DESATIVADO não pode ver a
-- foto do filho vinculado — só o vínculo em guardians não basta.
-- ---------------------------------------------------------------
create or replace function is_guardian_of_photo(p_photo_id uuid)
returns boolean language sql stable
security definer set search_path = public, pg_temp as $$
  select is_member() and exists (
    select 1 from photo_minors pm
    join guardians g on g.minor_id = pm.minor_id
    where pm.photo_id = p_photo_id and g.guardian_id = auth.uid()
  );
$$;

revoke execute on function is_guardian_of_photo from public;
grant execute on function is_guardian_of_photo to authenticated, service_role;

-- ---------------------------------------------------------------
-- Policies — minors / guardians / minor_consents: SÓ ADMIN ESCREVE
-- (docs/CONTRATO.md §8, invariante 6)
-- ---------------------------------------------------------------
create policy "read own minors" on minors
  for select to authenticated using (
    (select is_admin())
    or ((select is_member()) and exists (
          select 1 from guardians g
           where g.minor_id = minors.id and g.guardian_id = (select auth.uid())))
  );
create policy "admin manages minors" on minors
  for all to authenticated
  using ((select is_admin())) with check ((select is_admin()));

create policy "read own guardianship" on guardians
  for select to authenticated
  using ((select is_admin())
         or ((select is_member()) and guardian_id = (select auth.uid())));
create policy "admin manages guardianship" on guardians
  for all to authenticated
  using ((select is_admin())) with check ((select is_admin()));

create policy "read own minor consent" on minor_consents
  for select to authenticated
  using ((select is_admin())
         or ((select is_member()) and guardian_id = (select auth.uid())));
create policy "admin manages minor consent" on minor_consents
  for all to authenticated
  using ((select is_admin())) with check ((select is_admin()));

-- ---------------------------------------------------------------
-- Policies — photo_minors: marcação de foto é ação de quem sobe/revisa
-- (can_upload()), não é o vínculo responsável→menor da invariante 6.
-- ---------------------------------------------------------------
create policy "read photo minors" on photo_minors
  for select to authenticated using (
    (select is_admin())
    or ((select is_member()) and exists (
          select 1 from guardians g
           where g.minor_id = photo_minors.minor_id
             and g.guardian_id = (select auth.uid())))
  );
create policy "tag minors" on photo_minors
  for insert to authenticated
  with check ((select can_upload()) and tagged_by = (select auth.uid()));
create policy "admin untag" on photo_minors
  for delete to authenticated using ((select is_admin()));

-- ---------------------------------------------------------------
-- read photos: versão intermediária da fase 3 (docs/adr/0005).
-- Acrescenta só o ramo do responsável vinculado; o ramo de is_private
-- fica igual ao da fase 2 (fail closed) porque photo_grants só chega na
-- fase 4 — a versão "completa" do ARQUITETURA.md §5.2 é o estado
-- pós-fase-4, não o alvo desta migration.
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
      or (coalesce(contains_minors, true) = false and not is_private)
      or (coalesce(contains_minors, true) = true and is_guardian_of_photo(id))
    )
  );

-- ---------------------------------------------------------------
-- Índices
-- guardians.minor_id: guardians tem PK (guardian_id, minor_id) — sem este
-- índice, toda busca "quem é responsável por este menor" (usada em
-- is_guardian_of_photo, "read own minors" e "read photo minors") varreria
-- a tabela inteira em vez de usar o índice.
-- ---------------------------------------------------------------
create index guardians_minor_id_idx on guardians (minor_id);

-- ---------------------------------------------------------------
-- Grants/revokes
-- ---------------------------------------------------------------
revoke all on minors         from anon;
revoke all on guardians      from anon;
revoke all on minor_consents from anon;
revoke all on photo_minors   from anon;
