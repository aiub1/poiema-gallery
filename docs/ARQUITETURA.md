# Arquitetura — galeria-core

Versão 1.0 · Banco, worker e serviço facial. Documento vivo.
Complementar a `galeria-web/docs/ARQUITETURA.md`.

---

## 1. Visão geral

```
      galeria-web (Next.js)
        │            │
        │            └──── POST /face/search ──┐
        ▼                                      ▼
┌─────────────────┐                  ┌──────────────────┐
│  Supabase       │                  │ services/face    │
│  Postgres + RLS │◄─── grava ───────│ FastAPI/InsightF │
│  + pgvector     │                  │ (Fly.io)         │
└────────┬────────┘                  └────────▲─────────┘
         │                                    │
         │  polling jobs                      │ HTTP
         └──────────► worker (Go, Fly.io) ────┘
                            │
                            └──► Cloudflare R2 (lê original)
```

**Custo alvo: R$ 0/mês.** Uso interno, gratuito, sem fins lucrativos.

---

## 2. Dois modelos de acesso restrito — não confundir

| | Foto de menor | Foto privada de adulto |
|---|---|---|
| Flag | `contains_minors` | `is_private` |
| Quem vê | admin, uploader, **responsável vinculado** | admin, uploader, quem se achou por selfie |
| Mecanismo | vínculo cadastrado pela secretaria | `photo_grants` gerado pela busca |
| Rosto indexado? | **NUNCA** | sim, se o adulto consentiu |

Se as duas flags coexistem, vale a união das regras — e a foto continua **fora
do índice**, porque `contains_minors` bloqueia a indexação incondicionalmente.

---

## 3. Modelo de conteúdo

```
Evento "Culto 23/08/2026"
  ├── Sessão "Culto da manhã"
  └── Sessão "Culto da noite"

Evento "Festa Junina 2026"
  └── (sem sessões) → fotos soltas
```

`photos.session_id` é nulável. Sem sessões, a UI mostra tudo direto.

---

## 4. Schema

```sql
create extension if not exists vector;

-- ---------------------------------------------------------------
create type user_role as enum ('admin', 'uploader', 'member');

create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  avatar_key text,
  role       user_role not null default 'member',
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

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
-- menores: cadastro da secretaria, NÃO são usuários do sistema
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

-- ---------------------------------------------------------------
create type photo_status as enum
  ('pending_review','pending','indexing','indexed','failed','skipped');

create table photos (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references events(id) on delete cascade,
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

create table photo_minors (
  photo_id   uuid not null references photos(id) on delete cascade,
  minor_id   uuid not null references minors(id) on delete cascade,
  tagged_by  uuid not null references profiles(id) on delete restrict,
  created_at timestamptz not null default now(),
  primary key (photo_id, minor_id)
);

create table photo_grants (
  user_id    uuid not null references profiles(id) on delete cascade,
  photo_id   uuid not null references photos(id) on delete cascade,
  granted_at timestamptz not null default now(),
  primary key (user_id, photo_id)
);

-- ---------------------------------------------------------------
-- ⚠️ SENSÍVEL — só adultos consentidos, nunca menores
-- ---------------------------------------------------------------
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

create table face_consents (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  granted_at    timestamptz not null default now(),
  revoked_at    timestamptz,
  terms_version text not null
);

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

create table access_logs (
  id         bigserial primary key,
  user_id    uuid references profiles(id) on delete set null,
  action     text not null,
  target_id  uuid,
  created_at timestamptz not null default now()
);
create index on access_logs (user_id, created_at desc);
```

---

## 5. Row Level Security

### 5.1 Funções auxiliares

```sql
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

create or replace function is_guardian_of_photo(p_photo_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from photo_minors pm
    join guardians g on g.minor_id = pm.minor_id
    where pm.photo_id = p_photo_id and g.guardian_id = auth.uid()
  );
$$;
```

### 5.2 Policies

```sql
alter table profiles         enable row level security;
alter table events           enable row level security;
alter table sessions         enable row level security;
alter table minors           enable row level security;
alter table guardians        enable row level security;
alter table minor_consents   enable row level security;
alter table photos           enable row level security;
alter table photo_minors     enable row level security;
alter table photo_grants     enable row level security;
alter table photo_faces      enable row level security;
alter table face_consents    enable row level security;
alter table removal_requests enable row level security;
alter table jobs             enable row level security;
alter table access_logs      enable row level security;

-- profiles
create policy "read profiles" on profiles
  for select using (auth.uid() is not null);
create policy "update own profile" on profiles
  for update using (id = auth.uid())
  with check (id = auth.uid() and role = my_role() and is_active);
create policy "admin manages profiles" on profiles
  for all using (is_admin()) with check (is_admin());

-- events / sessions
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

-- minors / guardians: SÓ ADMIN ESCREVE
create policy "read own minors" on minors
  for select using (
    is_admin()
    or exists (select 1 from guardians g
                where g.minor_id = minors.id and g.guardian_id = auth.uid())
  );
create policy "admin manages minors" on minors
  for all using (is_admin()) with check (is_admin());

create policy "read own guardianship" on guardians
  for select using (guardian_id = auth.uid() or is_admin());
create policy "admin manages guardianship" on guardians
  for all using (is_admin()) with check (is_admin());

create policy "read own minor consent" on minor_consents
  for select using (guardian_id = auth.uid() or is_admin());
create policy "admin manages minor consent" on minor_consents
  for all using (is_admin()) with check (is_admin());

-- photos: regra central de visibilidade
create policy "read photos" on photos
  for select using (
    deleted_at is null
    and status <> 'pending_review'
    and auth.uid() is not null
    and (
      is_admin()
      or uploaded_by = auth.uid()
      or (
        coalesce(contains_minors, true) = false
        and (
          not is_private
          or exists (select 1 from photo_grants g
                      where g.photo_id = photos.id and g.user_id = auth.uid())
        )
      )
      or (coalesce(contains_minors, true) = true and is_guardian_of_photo(id))
    )
  );

create policy "insert photos" on photos
  for insert with check (can_upload() and uploaded_by = auth.uid());
create policy "update own photo" on photos
  for update using (is_admin() or uploaded_by = auth.uid())
  with check (is_admin() or uploaded_by = auth.uid());
create policy "delete photos" on photos for delete using (is_admin());

-- photo_minors
create policy "read photo minors" on photo_minors
  for select using (
    is_admin()
    or exists (select 1 from guardians g
                where g.minor_id = photo_minors.minor_id
                  and g.guardian_id = auth.uid())
  );
create policy "tag minors" on photo_minors
  for insert with check (can_upload() and tagged_by = auth.uid());
create policy "admin untag" on photo_minors for delete using (is_admin());

-- photo_grants
create policy "read own grants" on photo_grants
  for select using (user_id = auth.uid() or is_admin());
revoke insert, update, delete on photo_grants from anon, authenticated;

-- photo_faces: sem policy de select = ninguém lê
revoke all on photo_faces from anon, authenticated;

-- face_consents
create policy "read own consent" on face_consents
  for select using (user_id = auth.uid() or is_admin());
create policy "grant own consent" on face_consents
  for insert with check (user_id = auth.uid());
create policy "revoke own consent" on face_consents
  for update using (user_id = auth.uid());

-- removal_requests
create policy "read own requests" on removal_requests
  for select using (requested_by = auth.uid() or is_admin());
create policy "create request" on removal_requests
  for insert with check (can_upload() and requested_by = auth.uid());
create policy "admin reviews" on removal_requests
  for update using (is_admin()) with check (is_admin());

-- infra
revoke all on jobs from anon, authenticated;
create policy "admin reads logs" on access_logs for select using (is_admin());
```

### 5.3 Triggers de proteção de menores

```sql
create or replace function forbid_minor_faces()
returns trigger language plpgsql as $$
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
returns trigger language plpgsql as $$
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
```

### 5.4 Função de busca facial

```sql
create or replace function search_faces(
  p_embedding vector(512),
  p_event_id  uuid default null,
  p_threshold real default 0.38,
  p_limit     int  default 200
)
returns table (photo_id uuid, distance real)
language plpgsql volatile security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'não autenticado';
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

  create temp table _hits on commit drop as
    select f.photo_id as pid, min(f.embedding <=> p_embedding)::real as dist
    from photo_faces f
    join photos p on p.id = f.photo_id
    where p.deleted_at is null
      and coalesce(p.contains_minors, true) = false   -- terceira trava
      and (p_event_id is null or f.event_id = p_event_id)
      and (f.embedding <=> p_embedding) < p_threshold
    group by f.photo_id
    order by dist
    limit p_limit;

  insert into photo_grants (user_id, photo_id)
    select v_user, h.pid from _hits h
    join photos p on p.id = h.pid
    where p.is_private
  on conflict do nothing;

  return query select h.pid, h.dist from _hits h order by h.dist;
end;
$$;

revoke all on function search_faces from anon;
grant execute on function search_faces to authenticated;
```

---

## 6. Worker (Go)

Processo único, polling a cada 5 s, `FOR UPDATE SKIP LOCKED` para permitir mais
de uma instância sem duplicar trabalho.

```go
// pseudocódigo do laço principal
job := claimJob()                      // SELECT ... FOR UPDATE SKIP LOCKED
switch job.Type {
case "index_faces":
    photo := loadPhoto(job.PhotoID)
    if photo.ContainsMinors == nil || *photo.ContainsMinors {
        markSkipped(photo)             // PRIMEIRA TRAVA — nunca chama o serviço
        return
    }
    url   := signedReadURL(photo.StorageKey, 10*time.Minute)
    faces := faceService.Detect(url)
    saveFaces(photo.ID, faces)         // trigger é a segunda trava
    markIndexed(photo)
case "delete_objects":
    deleteFromR2(job.Keys)
case "purge_expired_embeddings":
    purgeOlderThan(retentionWindow)
}
```

Retry exponencial, máximo 5 tentativas, depois `failed` com `last_error`.
Jobs de tipos diferentes: `index_faces`, `delete_objects`,
`purge_expired_embeddings`.

Métricas expostas em `/metrics` (Prometheus): fila pendente, duração por job,
taxa de falha.

---

## 7. Serviço facial (Python)

```
POST /detect   { image_url }        → [{ embedding, bbox, quality }]
POST /embed    multipart: selfie    → { embedding }
GET  /health
GET  /metrics
```

- InsightFace `buffalo_l`, 512 dimensões, L2-normalizado.
- Auth por header `X-Service-Token`.
- `/embed` roda **inteiramente em memória**. Sem `tempfile`, sem escrita, sem log
  do payload. Existe teste que falha se algo for gravado em disco.
- `/detect` recebe URL assinada e faz streaming — não persiste a imagem.
- CPU basta: ~0,3–1 s por foto. 1 worker, 2 threads no free tier do Fly.io.

Limiar de similaridade: cosseno `< 0.38` como ponto de partida.
**Calibrar com fotos reais do primeiro evento antes de liberar.** Falso positivo
(devolver estranho) é muito pior que falso negativo aqui.

---

## 8. Storage (R2)

```
events/{event_id}/photos/{photo_id}/original.webp
events/{event_id}/photos/{photo_id}/web.webp
events/{event_id}/photos/{photo_id}/thumb.webp
events/{event_id}/cover.webp
```

Bucket privado. Leitura por URL assinada de 15 min, sempre após checar permissão
no banco. Exclusão de foto é soft delete; job `delete_objects` limpa o R2 após
30 dias.

---

## 9. Infra como código

OpenTofu em `infra/`: bucket R2, políticas de acesso, apps do Fly.io, secrets.
Estado remoto no R2. Supabase permanece no console (provider imaturo) —
documentar as configurações manuais em `docs/adr/0005-supabase-manual-setup.md`.

---

## 10. Testes

| Camada | Ferramenta | Foco |
|---|---|---|
| Banco | pgTAP | RLS, triggers, `search_faces` |
| Worker | `go test` | claim de job, retry, trava de menores |
| Serviço facial | pytest | `/embed` não escreve em disco |

Cenários pgTAP obrigatórios listados em `CLAUDE.md` seção 8. Não remover.

CI:
```
pull_request → supabase start · db reset · test db · go test · pytest · tofu validate
main         → migrations no remoto · deploy Fly.io · smoke test
```

---

## 11. Observabilidade

OpenTelemetry no worker e no serviço facial, exportando para Grafana Cloud.

Rastrear: tamanho da fila, latência de indexação, taxa de erro do serviço facial,
tempo de `search_faces`.

**Nunca** exportar: embedding, imagem, e-mail, IP em claro.

---

## 12. LGPD — checklist

- [ ] Aviso visível nos cultos sobre fotos e publicação interna
- [ ] Autorização do responsável registrada em `minor_consents`
- [ ] Consentimento do adulto para busca facial em `face_consents`
- [ ] Política de privacidade com finalidade, retenção e responsável
- [ ] "Excluir meus dados faciais" funcional
- [ ] "Remover fotos do meu filho" acessível ao responsável
- [ ] Job de retenção apagando embeddings 1 ano após o evento
- [ ] Nenhum log com embedding, selfie ou IP em claro
- [ ] Revisão jurídica antes de abrir aos membros

---

## 13. Roadmap

**Fase 1 — Fundação.** Migrations de `profiles`, `events`, `sessions`. RLS e
pgTAP. CI verde.

**Fase 2 — Fotos.** `photos`, `removal_requests`, `jobs`. Bucket R2 via OpenTofu.

**Fase 3 — Menores.** `minors`, `guardians`, `minor_consents`, `photo_minors`,
policies e triggers de proteção. **Antes de existir qualquer embedding.**

**Fase 4 — Faces.** `photo_faces`, `face_consents`, `photo_grants`,
`search_faces`, serviço Python, worker Go.

**Fase 5 — Acabamento.** Retenção automática, métricas, calibração do limiar.

A fase 3 vem antes da 4 de propósito.

---

## 14. Planos gratuitos (agosto/2026)

| Serviço | Free | Onde aperta |
|---|---|---|
| Supabase | 500 MB banco, 5 GB egress, 2 projetos | **Pausa após 7 dias sem uso**, sem backup |
| Cloudflare R2 | 10 GB, egress ilimitado | Volume de fotos |
| Fly.io | Allowance pequeno | Fila grande de indexação |
| Grafana Cloud | 10k séries, 50 GB logs | Suficiente com folga |

Confira os números atuais — mudam com frequência.

**A pausa do Supabase é o risco real:** a igreja pode passar dias sem acesso.
Cron gratuito no GitHub Actions batendo a cada 2 dias resolve. Se o acervo
crescer, Supabase Pro (US$ 25/mês) resolve pausa, backup e espaço.
