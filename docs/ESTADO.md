# Estado do projeto

Última atualização: 2026-09-01 · snapshot, não documento vivo como
`ARQUITETURA.md`. Reflete o que existe de fato no branch `develop`, não o
plano — para o plano completo ver `ARQUITETURA.md` §13 (Roadmap).

---

## Fase atual

**Fase 1 — Fundação: ✅ concluída** (PR #1, mergeado em `develop`).
Em andamento: nenhuma — próxima fase (2 — Fotos) ainda não começou.

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
- 28 testes pgTAP, passando localmente via `npx supabase test db`:
  - `00_foundation.sql` (25): um cenário por papel (admin/uploader/member/
    perfil inativo/anon), incluindo autopromoção, delete em `profiles`,
    provisionamento inativo e uploader editando sessão alheia.
  - `010_schema_guards.sql` (3): guardas dinâmicos varrendo o catálogo —
    toda tabela em `public` tem RLS, toda função `security definer` fixa
    `search_path` com `pg_temp`, nenhuma tabela concede privilégio a `anon`.
- `seed.sql` com 4 perfis (um por papel, mais uma conta desativada), 1
  evento, 1 sessão — perfis criados via `auth.users` (trigger de
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
  `0003-profile-provisioning.md`. `CLAUDE.md` também versionado.

### O que ainda **não** existe
- Tabelas `photos`, `removal_requests`, `jobs`, `minors`, `guardians`,
  `minor_consents`, `photo_minors`, `photo_faces`, `face_consents`,
  `photo_grants`, `access_logs` — todas fase 2+.
- Qualquer código em `worker/` e `services/face/` (só scaffolding de pastas
  e READMEs).
- `infra/` (OpenTofu) — só README, nenhum `.tf`.
- Bucket R2, apps Fly.io, projeto Supabase remoto — nada provisionado.
- `docs/adr/0005-supabase-manual-setup.md`, referenciada em
  `ARQUITETURA.md` §9 mas ainda não escrita.
- `galeria-web` — repositório separado, fora do escopo deste checkout.

---

## Ambiente local

- Stack Supabase validado via Docker (`npx supabase start`), mas **parado**
  no momento — não fica rodando entre sessões.
- Sem Go nem OpenTofu instalados neste ambiente (não bloqueia a Fase 1, vai
  bloquear a Fase 2/4 quando `worker/` e `infra/` ganharem código).

---

## Próximo passo natural

Fase 2 — Fotos (`ARQUITETURA.md` §13): tabelas `photos`, `removal_requests`,
`jobs` + policies/índices + pgTAP correspondente, e bucket R2 via OpenTofu
(`infra/`).
