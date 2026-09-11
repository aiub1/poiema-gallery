# Estado do projeto

Última atualização: 2026-09-11 · snapshot, não documento vivo como
`ARQUITETURA.md`. Reflete o que existe de fato no branch `develop` mais o
que está implementado localmente aguardando merge (ver nota de cada fase),
não o plano — para o plano completo ver `ARQUITETURA.md` §13 (Roadmap).

---

## Fase atual

**Fase 1 — Fundação: ✅ concluída** (PR #1 e PR #2, ambos mergeados em
`develop`). O PR #1 original ficou atrasado em relação a `ARQUITETURA.md`
v1.1; o PR #2 completou `is_member()`, os triggers de provisionamento e de
colunas privilegiadas, `sessions.created_by`, o `revoke` de `anon` e os
guardas dinâmicos (detalhes na seção Banco abaixo).

**Fase 2 — Fotos: ✅ implementada localmente**, branch `feat/phase2-photos`,
aguardando revisão e merge em `develop`. Migration `photos`,
`removal_requests`, `jobs`, `access_logs`, soft delete de `events` e
`photo_faces` antecipada da fase 4 — decisões registradas em
[ADR 0004](adr/0004-events-soft-delete-and-photo-faces-timing.md).
Bucket R2 via OpenTofu **não entrou** nesta etapa (fora do escopo tratado
até aqui).

**Fase 3 — Menores: ✅ implementada localmente**, branch
`feat/phase3-minors`, aguardando revisão e merge em `develop`. Migration
`minors`, `guardians`, `minor_consents`, `photo_minors`,
`is_guardian_of_photo()`, `read photos` com o ramo do responsável
vinculado — decisões registradas em [ADR
0005](adr/0005-read-photos-phase-progression-and-consent-scope.md).
`photo_grants`/`search_faces` (fase 4) **não entraram** nesta migration; o
ramo de `is_private` em `read photos` continua fail closed até lá.
As três pendências de schema do `ARQUITETURA.md` §15
(`profiles_full_name_not_blank`, unicidade de nome de sessão por evento,
índice em `events.created_by`) foram fechadas numa migration à parte —
branch `fix/schema-pendencias`, já mergeado em `develop` (PR #6).

**Fase 4a — Faces, banco: ✅ implementada localmente**, branch
`feat/phase4a-faces`, aguardando revisão e merge em `develop`. Migration
`face_consents`, `photo_grants`, `search_faces`, terceiro e último estado
de `read photos` — decisões registradas em [ADR
0009](adr/0009-photo-grants-revocation-and-search-faces-hits-cte.md).
Serviço Python e worker Go (fase 4b) ainda não começaram.

---

## O que existe

### Banco (`supabase/`)
- Migration `20260830060023_foundation.sql`: `profiles`, `events`,
  `sessions`, RLS completa para as três tabelas, alinhada com
  `docs/ARQUITETURA.md` v1.1:
  - Funções `my_role()`/`is_member()`/`is_admin()`/`can_upload()`, todas
    `security definer` com `search_path = public, pg_temp`.
  - Toda leitura passa por `is_member()` (perfil ativo), nunca por
    `auth.uid() is not null`.
  - Trigger `trg_profiles_privileged_columns` (security invoker) congela
    `role`/`is_active`/`id`/`created_at` para quem não é admin.
  - Trigger `trg_on_auth_user_created` provisiona o perfil a partir de
    `auth.users`, sempre `member` + `is_active = false` (ADR 0003).
  - `profiles` sem policy de `delete` — nem para admin — com
    `revoke delete ... from authenticated`.
  - `sessions.created_by`, com policies de insert/update amarradas a ele.
  - `revoke all ... from anon` em `profiles`/`events`/`sessions`.
  - Índices nomeados: `profiles_role_idx`, `events_event_date_idx`,
    `sessions_event_id_position_idx`.
- Migration `20260910224708_phase2_photos.sql` (fase 2):
  - `events` ganha `deleted_at` (soft delete) e `revoke delete ... from
    authenticated` — sem `DELETE` real em `events` para nenhum papel
    autenticado, admin incluído. Gravar `deleted_at` exige `service_role`
    (rota de servidor), nunca o JWT do cliente — ver
    [ADR 0004](adr/0004-events-soft-delete-and-photo-faces-timing.md).
  - `photos`: `event_id` com `on delete restrict` (não `cascade` — fecha a
    pendência do `ARQUITETURA.md` §15), policy de leitura simplificada para
    o que existe nesta fase (sem `guardians`/`photo_grants`, que só chegam
    nas fases 3/4), exige também que o evento da foto não esteja
    soft-deletado. `DELETE` só por admin.
  - `photo_faces` **antecipada da fase 4** (ADR 0004): schema completo,
    índice `hnsw`, sem policy de `select`, `revoke all` de `anon` e
    `authenticated`. Traz junto os dois triggers de proteção de menores
    (`trg_forbid_minor_faces`, `trg_purge_faces_on_minor_flag` —
    `CLAUDE.md` §3, segunda e terceira camada).
  - `removal_requests`, `jobs` (sem nenhuma policy — só `service_role`
    escreve), `access_logs` (só admin lê).
- Migration `20260911054031_phase3_minors.sql` (fase 3):
  - `minors`, `guardians`, `minor_consents`, `photo_minors`: RLS completa,
    escrita restrita a `admin` em `minors`/`guardians`/`minor_consents`
    (`CONTRATO.md` invariante 6), `photo_minors` marcada por quem sobe/
    revisa (`can_upload()`), desmarcada só por `admin`.
  - `is_guardian_of_photo()`: `security definer` com `pg_temp`, chama
    `is_member()` internamente — responsável desativado não vê a foto do
    filho mesmo com vínculo intacto.
  - `read photos` ganha o ramo do responsável vinculado. O ramo de
    `is_private` fica igual ao da fase 2 (fail closed) — `photo_grants` só
    chega na fase 4. Três estados documentados em [ADR
    0005](adr/0005-read-photos-phase-progression-and-consent-scope.md).
  - `minor_consents` é só registro legal nesta fase — não gateia leitura
    (decisão deliberada, ADR 0005): revogar consentimento não pode cegar o
    próprio responsável para a foto do filho.
- Migration `20260911062131_schema_cleanup_pendencias.sql`: fecha as três
  pendências do `ARQUITETURA.md` §15 — `profiles_full_name_not_blank` (já
  documentada em §4, nunca tinha entrado em migration),
  `sessions_event_id_name_key` (índice único **normalizado**
  `(event_id, lower(btrim(name)))`, não o `unique (event_id, name)` literal
  — ver [ADR 0008](adr/0008-session-name-uniqueness-normalized.md)) e
  `events_created_by_idx`.
- Migration `20260911123330_phase4a_faces.sql` (fase 4a):
  - `face_consents`: RLS completa, só o próprio titular (ou admin) lê/grava
    o próprio consentimento.
  - `photo_grants`: sem policy de insert/update — só `search_faces` grava,
    como `security definer`. Ganha policy de `delete` **só para admin**
    (válvula de escape para falso positivo do limiar de similaridade,
    ainda não calibrado — [ADR
    0009](adr/0009-photo-grants-revocation-and-search-faces-hits-cte.md)).
    Grant não removido é permanente: revogar `face_consents` bloqueia
    buscas novas, não apaga grants já emitidos.
  - `read photos` chega ao terceiro e último estado: troca só o ramo de
    `is_private` para incluir `photo_grants`, o ramo de `contains_minors`
    não mudou desde a fase 3.
  - `search_faces`: `is_member()`, consentimento ativo, rate limit de
    20 buscas/hora via `access_logs`, terceira trava de `contains_minors`
    (redundante com as duas do trigger em `photo_faces`, de propósito).
    Implementada com CTE que grava e lê no mesmo `WITH`, não com
    `create temp table ... on commit drop` como `ARQUITETURA.md` §5.4
    documentava originalmente — motivo em ADR 0009 (a versão com tabela
    temporária quebrava numa segunda chamada dentro da mesma transação).
- 81 testes pgTAP, passando localmente via `npx supabase test db`:
  - `00_foundation.sql` (25): um cenário por papel (admin/uploader/member/
    perfil inativo/anon), incluindo autopromoção, delete em `profiles`,
    provisionamento inativo e uploader editando sessão alheia. Ajustado na
    fase 2: `DELETE` em `events` agora espera `42501` (privilégio revogado),
    não mais bloqueio silencioso por RLS.
  - `010_schema_guards.sql` (3): guardas dinâmicos varrendo o catálogo —
    toda tabela em `public` tem RLS, toda função `security definer` fixa
    `search_path` com `pg_temp`, nenhuma tabela concede privilégio a `anon`.
  - `02_photos_rls.sql` (23, fase 2): visibilidade de `photos` (pública,
    menor, privada, `pending_review`, soft-deletada, evento soft-deletado),
    `DELETE` de foto (uploader bloqueado, admin permitido), fluxo de
    `removal_requests`, `jobs` fechado para `authenticated`, as duas travas
    de `photo_faces` e o soft delete de `events` (incluindo a
    impossibilidade de gravar `deleted_at` pelo JWT do próprio admin).
  - `03_minors_rls.sql` (9, fase 3): responsável vinculado ativo lê foto
    pública e privada do filho (união das regras), vínculo não criável por
    `member`/`uploader`, `member` não insere em `minors`, `member` não lê
    foto de menor não vinculado a ele, responsável inativo não lê a foto do
    filho, `uploader` marca `photo_minors` mas não cria vínculo, `admin`
    cria vínculo em `guardians`.
  - `04_schema_pendencias.sql` (7): `full_name` vazio e só-com-espaço
    rejeitados (`23514`), sessão duplicada no mesmo evento rejeitada tanto
    no nome idêntico quanto em capitalização/espaço diferente (`23505`),
    mesmo nome em evento diferente aceito (unicidade é por evento),
    `events_created_by_idx` existe.
  - `05_faces_rls.sql` (14, fase 4a): perfil inativo/sem consentimento/
    consentimento revogado não executam `search_faces`, rate limit dispara
    na 21ª busca, foto com `contains_minors = true` nunca aparece no
    resultado mesmo com embedding plantado à força (trigger de insert
    desligado só dentro da transação de teste, para isolar a terceira
    trava das outras duas), foto soft-deletada não aparece, grant emitido
    libera a leitura da foto privada em `read photos`, admin remove o
    grant mas member/uploader (mesmo o titular) não conseguem, e a foto
    volta a ficar invisível depois da remoção.
- `seed.sql` com 4 perfis (um por papel, mais uma conta desativada), 1
  evento, 1 sessão, 3 fotos do uploader (`contains_minors` true/false/null),
  1 `removal_request` pendente, 1 `job` na fila, 1 menor com vínculo e
  consentimento registrados, a marcação `photo_minors` na foto que já tem
  `contains_minors = true`, 1 `face_consents` ativo do membro seed e 1
  embedding sintético em `photo_faces` na única foto que pode ser indexada
  (`contains_minors = false`) — perfis criados via `auth.users` (trigger de
  provisionamento) e ativados por `update`, não por `insert` direto.
- `config.toml` gerado por `supabase init`, Postgres 15 fixado (major_version).

### CI (`.github/workflows/ci.yml`)
- Job `pr-title`: valida título do PR contra Conventional Commits.
- Job `database`: `supabase start` → `db reset` → `test db`, roda de verdade.
- Jobs `worker`, `face-service`, `infra`: existem no workflow mas ficam
  no-op (guardados por `hashFiles`) até `worker/go.mod`,
  `services/face/requirements.txt` e `infra/*.tf` existirem.
- Job `deploy` (branch `main`): esqueleto com TODOs, sem credenciais
  configuradas ainda.

### Padrão de commits/branches/PRs
- `CONTRIBUTING.md` documenta o padrão (Conventional Commits com escopo
  obrigatório, branch `tipo/slug`, template de PR).
- `.husky/pre-commit` (nome de branch) e `.husky/commit-msg` (commitlint)
  ativos via `npm install` (script `prepare`).
- `commitlint.config.js` define os escopos válidos: `db`, `worker`, `face`,
  `infra`, `ci`, `docs`, `deps`, `repo`.
- `.github/PULL_REQUEST_TEMPLATE.md` em uso.
- `docs/adr/` versionado (saiu do `.gitignore`): `0001-padrao-commits-
  branches-prs.md`, `0002-migration-conventions.md`,
  `0003-profile-provisioning.md`,
  `0004-events-soft-delete-and-photo-faces-timing.md`. `CLAUDE.md` também
  versionado.

### O que ainda **não** existe
- Qualquer código em `worker/` e `services/face/` (fase 4b) — o consumo
  real de `search_faces`/`photo_faces` pelo worker Go e pelo serviço facial
  Python. Banco da fase 4a (`face_consents`, `photo_grants`,
  `search_faces`) já existe, implementado localmente.
- Bucket R2 via OpenTofu para a fase 2 — não entrou nesta migration, fora do
  escopo tratado.
- Apps Fly.io, projeto Supabase remoto — nada provisionado.
- Bucket R2: código em `infra/` (branch `feat/infra-r2-bucket`,
  `cloudflare_r2_bucket` fixado em provider `4.52.9`/Tofu `1.12.6`,
  `tofu validate` limpo), mas **`tofu apply` não foi rodado** — nada
  provisionado de verdade ainda. Credencial S3-compatible do bucket fica
  fora do Tofu de propósito — passo manual documentado em
  `infra/README.md`. Decisões registradas em [ADR
  0006](adr/0006-supabase-manual-setup.md) e [ADR
  0007](adr/0007-tfstate-separate-bucket.md).
- `galeria-web` — repositório separado, fora do escopo deste checkout.

---

## Ambiente local

- Stack Supabase validado via Docker (`npx supabase start`), mas **parado**
  no momento — não fica rodando entre sessões.
- Sem Go nem OpenTofu instalados neste ambiente (não bloqueia a Fase 1, vai
  bloquear a Fase 2/4 quando `worker/` e `infra/` ganharem código).

---

## Próximo passo natural

Merge de `feat/phase2-photos`, `feat/phase3-minors` e `feat/phase4a-faces`
em `develop`, depois bucket R2 via OpenTofu (`infra/`, pendente da fase 2,
`tofu apply` ainda não rodado) e Fase 4b — Faces, worker e serviço
(`ARQUITETURA.md` §13): consumo real de `search_faces`/`photo_faces` pelo
serviço Python e pelo worker Go.
