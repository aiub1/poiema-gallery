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
  `sessions`, funções `my_role()`/`is_admin()`/`can_upload()`, RLS completa
  para essas três tabelas.
- 15 testes pgTAP (`supabase/tests/00_foundation.sql`), um cenário por papel
  (admin/uploader/member/anon) — passando localmente via
  `npx supabase test db`.
- `seed.sql` com 3 perfis (um por papel), 1 evento, 1 sessão.
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
- Decisão registrada em `docs/adr/0001-padrao-commits-branches-prs.md`
  (**local, não versionado** — `docs/adr/` está no `.gitignore`).

### O que ainda **não** existe
- Tabelas `photos`, `removal_requests`, `jobs`, `minors`, `guardians`,
  `minor_consents`, `photo_minors`, `photo_faces`, `face_consents`,
  `photo_grants`, `access_logs` — todas fase 2+.
- Qualquer código em `worker/` e `services/face/` (só scaffolding de pastas
  e READMEs).
- `infra/` (OpenTofu) — só README, nenhum `.tf`.
- Bucket R2, apps Fly.io, projeto Supabase remoto — nada provisionado.
- `docs/adr/` com histórico de outras decisões (só a 0001 existe, local).
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
