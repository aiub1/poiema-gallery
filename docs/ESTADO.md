# Estado do projeto

Última atualização: 2026-10-02 · snapshot, não documento vivo como
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

**Fase 4b — Faces, serviço Python: ✅ implementada localmente**, branch
`feat/phase4b-face-service`, aguardando revisão e merge em `develop`.
`services/face/`: `/detect`, `/embed`, `/health`, `/metrics`, auth por
`X-Service-Token`, modelo empacotado na imagem Docker (não baixado em
runtime) — decisões registradas em [ADR
0010](adr/0010-face-service-implementation.md). `fly.toml` versionado
(`services/face/fly.toml`, app `poiema-gallery-face`).

**Fase 4b — Faces, worker Go: ✅ implementada localmente**, branch
`feat/phase4b-worker`, aguardando revisão e merge em `develop`.
`worker/cmd/worker`, `worker/internal/{jobs,faces,storage}` — claim de job
(`FOR UPDATE SKIP LOCKED` + lease de 10 min para job travado por worker
morto), retry exponencial (máx. 5 tentativas), os três tipos de job
(`index_faces` completo; `delete_objects` completo no código, sem efeito
até o bucket R2 existir; `purge_expired_embeddings` reconhecido e marcado
`skipped`, implementação real pendente de revisão jurídica —
`ARQUITETURA.md` §12), cliente HTTP do serviço facial, cliente R2
(URL assinada de leitura, `delete_objects`). Decisões em [ADR
0011](adr/0011-worker-service-role.md). `Dockerfile` e `fly.toml`
versionados (app `poiema-gallery-workerr`).

> ✅ **Pendência antes bloqueante, fechada:** o worker usa um role Postgres
> restrito (`worker_service`, `bypassrls`, grants só em
> `photos`/`photo_faces`/`jobs` — ADR 0011), não `service_role`. A migration
> `20260914023701_worker_service_role.sql` (branch
> `feat/worker-service-role`) cria o role e os grants; 25 novos cenários
> pgTAP em `06_worker_service.sql` (106 no total, todos verdes). Falta só
> um passo manual fora do repo: a senha do role no ambiente remoto, via
> `alter role worker_service password '...'` — documentado junto dos
> outros segredos manuais em [ADR 0006](adr/0006-supabase-manual-setup.md).
> Sem essa senha em `WORKER_DATABASE_URL`, `go run ./cmd/worker` ainda não
> conecta em produção, mas o bloqueio de schema (`supabase/`) está
> resolvido.

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
- Migration `20260914023701_worker_service_role.sql`: role `worker_service`
  (`login bypassrls`) para o worker Go — `select`/`update` em
  `photos`/`jobs`, `insert` em `photo_faces`, `usage` em `public` e
  `extensions`, membership em `postgres` (os dois últimos e o de schema
  são pré-requisitos mecânicos, não ampliam o alcance do role — nota de
  aplicação em [ADR 0011](adr/0011-worker-service-role.md)). Sem senha —
  passo manual, [ADR 0006](adr/0006-supabase-manual-setup.md).
- Migration `20261002203010_public_events.sql` (0007, branch
  `feat/public-events`): `events.is_public`, trigger `trg_events_public_flag`
  (só admin muda), `public_photos_of()` interna e as funções públicas
  `public_event`, `public_event_sessions`, `public_event_photos`,
  `public_photo` ([ADR 0014](adr/0014-public-events.md)). `anon` continua sem
  privilégio em tabela. **Escrita e testada localmente; ainda NÃO aplicada no
  remoto** — aplicação por `migrations.yml` com dry-run (ADR 0013). Depois
  dela: criar o evento GetUp 2026 (passo manual no SQL Editor), CORS do
  bucket para o site do GetUp (PR de `infra/`), regenerar tipos e copiar
  `CONTRATO.md` 1.2 para o `galeria-web`.
- 128 testes pgTAP (106 anteriores + 22 de `07_public_events.sql`), passando
  localmente via `npx supabase test db`:
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
  - `06_worker_service.sql` (25, migration do role do worker): os três
    grants da ADR 0011 funcionam (`select`/`update` em `photos`/`jobs`,
    `insert` em `photo_faces`); `photo_faces` sem `update` nem `delete`
    para este role; `trg_forbid_minor_faces` continua bloqueando o
    conteúdo mesmo com `bypassrls` e grant de `insert` (foto com
    `contains_minors` verdadeiro e nula); as oito tabelas negadas
    (`profiles`, `guardians`, `minors`, `minor_consents`, `face_consents`,
    `photo_grants`, `access_logs`, `removal_requests`) inalcançáveis tanto
    para leitura quanto para escrita.
- `seed.sql` com 4 perfis (um por papel, mais uma conta desativada), 1
  evento, 1 sessão, 3 fotos do uploader (`contains_minors` true/false/null),
  1 `removal_request` pendente, 1 `job` na fila, 1 menor com vínculo e
  consentimento registrados, a marcação `photo_minors` na foto que já tem
  `contains_minors = true`, 1 `face_consents` ativo do membro seed e 1
  embedding sintético em `photo_faces` na única foto que pode ser indexada
  (`contains_minors = false`) — perfis criados via `auth.users` (trigger de
  provisionamento) e ativados por `update`, não por `insert` direto.
- `config.toml` gerado por `supabase init`, Postgres 15 fixado (major_version).

### Serviço facial (`services/face/`, fase 4b)
- `main.py`: FastAPI com `/detect`, `/embed`, `/health` (sem auth),
  `/metrics` (com auth — decisão registrada em [ADR
  0010](adr/0010-face-service-implementation.md)). Auth por
  `X-Service-Token` (`hmac.compare_digest`) em `/detect`, `/embed` e
  `/metrics`.
  - `/embed`: multipart em memória, sem `tempfile`; eleva
    `MultiPartParser.max_file_size` em vez de gravar em disco acima de
    1 MB (limite padrão do Starlette) — ver ADR 0010, decisão 2.
  - `/detect`: busca a imagem via `httpx` (streaming em memória, sem
    disco), descarta rostos abaixo de `min_quality`.
  - `get_face_app`: carrega o InsightFace sob demanda, uma vez por
    processo — nunca no import do módulo nem no `lifespan`, para que os
    testes substituam por um stub sem baixar o modelo real.
- `Dockerfile`: modelo `buffalo_l` baixado em build-time
  (`download_model.py`, builder stage) para `/opt/insightface/models` —
  nunca em runtime. `insightface` instalado com `--no-deps` (evita
  `matplotlib`/`scipy`/`albumentations`/`scikit-learn`, nunca usados —
  só existem por causa do `MaskRenderer`, que este serviço não chama);
  `requirements.txt` declara as dependências reais (`onnx`,
  `scikit-image`, `requests`, `tqdm`). `uvicorn ... --no-access-log` (o
  log de acesso padrão loga IP do cliente em claro, proibido por
  `CLAUDE.md` §5.2). Decisões e números medidos (tamanho da imagem antes/
  depois, cold start) em [ADR
  0010](adr/0010-face-service-implementation.md), decisão 6 — validado com
  `docker build` + container real rodando `/health` e `/embed` com o
  modelo de verdade (não só os testes com stub).
- `tests/`: 12 testes pytest — 401 sem token/com token errado (`/detect`,
  `/embed`, `/metrics`), `/health` sem auth, `/embed` 422 sem rosto, melhor
  rosto retornado quando há mais de um, `/embed` não escreve em disco
  (monkeypatch de `tempfile.*` + snapshot de diretório), `/embed` não loga
  embedding/nome de arquivo/token, `/detect` filtra por `min_quality` e
  converte bbox — todos offline, sem modelo real (`FakeFaceAnalysis` via
  `app.dependency_overrides`) e sem rede real (`respx` mockando `httpx`).
- `requirements.txt`/`requirements-dev.txt`: versões fixadas. `ruff`
  (limpo) e `mypy --strict` (limpo) configurados em `pyproject.toml`.

### CI/CD (`.github/workflows/`, ADR 0012, ADR 0013)
- `develop` = integração (destino usual de PR); `master` = produção (só
  recebe PR de release `develop` → `master`). `ci.yml` roda em
  `pull_request` para as duas; `deploy.yml` só em `push` para `master`.
- `ci.yml`, job `changes`: `dorny/paths-filter` decide se `worker/` e/ou
  `services/face/` mudaram — os jobs `worker`/`face-service` só rodam de
  verdade nesse caso, mas sempre reportam (como `skipped` quando não se
  aplica), para não travar branch protection.
- Job `pr-title`: valida título do PR contra Conventional Commits.
- Job `database`: `supabase start` → `db reset` → `test db`, roda de verdade.
- Job `face-service`: `ruff check .`, `mypy main.py`, `pytest`.
- Job `worker`: `go build`, `go vet`, `gofmt -l` e `go test`.
- Job `infra`: existe no workflow mas fica no-op (guardado por `hashFiles`)
  até `infra/*.tf` ter arquivos versionados no branch em avaliação.
- `migrations.yml`: workflow separado, só `workflow_dispatch` (ADR 0013) —
  não roda em push/PR. Roda `supabase db push --dry-run` antes do `db push`
  de verdade, para dar chance de abortar antes de escrever no banco remoto.
- `deploy.yml`: um job por app (`deploy-face`, `deploy-worker`), cada um
  com seu próprio secret (`FLY_TOKEN_FACE`/`FLY_TOKEN_WORKER`) e seu
  `concurrency` group; dispara em `push` para `master` (só do app cuja
  pasta mudou) ou por `workflow_dispatch` manual. `flyctl deploy
  --local-only --ha=false`. Smoke test de `/health` com retry só no
  `deploy-face` (worker não expõe HTTP público). **Secrets ainda não
  configurados no GitHub** — bloqueante para o primeiro deploy real via
  Actions.

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
- A senha do role `worker_service` no ambiente remoto — passo manual fora
  do repo (`alter role ... password`), documentado em [ADR
  0006](adr/0006-supabase-manual-setup.md). A migration que cria o role e
  os grants já existe e está testada; sem a senha em
  `WORKER_DATABASE_URL`, o worker ainda não conecta em produção.
- Bucket R2 via OpenTofu para a fase 2 — não entrou nesta migration, fora do
  escopo tratado.
- Apps Fly.io, projeto Supabase remoto — nada provisionado. `fly.toml` de
  `services/face/` e `worker/` já versionados, mas `fly apps create`/`fly
  deploy` ainda não rodaram.
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
- Go 1.23.12 instalado localmente em `~/go1.23.12` (tarball oficial, sem
  `sudo` disponível neste ambiente — não em `/usr/local`); `worker/go.mod`
  fixa `go 1.23.12`. `go build`, `go vet`, `gofmt -l` e `go test ./...`
  validados localmente. OpenTofu segue não instalado (bloqueia `infra/`
  quando ganhar código de verdade). Sem `pip`/`venv` de sistema neste
  ambiente — `services/face/` foi validado (`ruff`, `mypy`, `pytest`)
  rodando dentro de um container `python:3.12-slim` via Docker, não em venv
  local.

---

## Próximo passo natural

Merge de `feat/phase2-photos`, `feat/phase3-minors`, `feat/phase4a-faces`,
`feat/phase4b-face-service`, `feat/phase4b-worker` e
`feat/worker-service-role` em `develop`. Antes de qualquer deploy: definir
a senha do role `worker_service` no remoto e carregá-la em
`WORKER_DATABASE_URL` via `fly secrets set` (ADR 0006) — sem isso o worker
ainda não conecta em banco nenhum, mesmo com a migration aplicada. Depois:
bucket R2 via OpenTofu (`infra/`, pendente da fase 2, `tofu apply` ainda
não rodado), necessário para o worker assinar URLs de leitura e rodar
`delete_objects`
de verdade.
