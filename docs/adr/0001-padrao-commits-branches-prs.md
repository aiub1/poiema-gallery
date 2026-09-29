# 0001 — Padrão de commits, branches e PRs

Status: aceita · 2026-08-30

## Contexto

O repositório tem dois contribuidores (João Aiub, Rafael Souza) e um contrato
formal com o `galeria-web` (`docs/CONTRATO.md`), onde mudanças de schema
exigem coordenação entre os dois repos. Sem convenção fixa de commit/branch/PR,
o histórico fica difícil de auditar — em particular saber, só pelo log, se um
commit mexeu em RLS, no worker ou no serviço facial, que é exatamente o tipo
de coisa que precisa ficar óbvio num projeto que lida com dado sensível
(LGPD, ARQUITETURA.md §12).

## Decisão

- **Commits**: Conventional Commits com escopo obrigatório —
  `tipo(escopo): descrição`. Escopos fixos e atrelados à estrutura do repo:
  `db`, `worker`, `face`, `infra`, `ci`, `docs`, `deps`, `repo`.
- **Branches**: `tipo/slug-kebab-case`, mesmos tipos dos commits. `main`,
  `master` e `develop` ficam de fora da regra.
- **PRs**: título no mesmo formato do commit (vira changelog em squash merge);
  descrição segue `.github/PULL_REQUEST_TEMPLATE.md`, com checklist cobrindo
  RLS, pgTAP e regeneração de tipos para o `galeria-web`.
- **Enforcement**: husky (`pre-commit` valida o nome da branch via
  `scripts/check-branch-name.sh`; `commit-msg` roda `commitlint` com
  `commitlint.config.js`) localmente, e um job de CI
  (`amannn/action-semantic-pull-request`) validando o título do PR — cobre
  quem commitar com `--no-verify`.

Detalhes completos em `CONTRIBUTING.md`.

## Consequências

- `npm install` passa a ser obrigatório antes do primeiro commit (é o que
  ativa os hooks via script `prepare`).
- Hook local é só conveniência — pode ser burlado com `--no-verify`; quem
  garante o padrão de verdade é o job de CI no PR.
- A lista de escopos (`commitlint.config.js` e o input `scopes` do job
  `pr-title` em `.github/workflows/ci.yml`) precisa ser atualizada junto se
  a estrutura de diretórios do repo mudar (ex.: novo serviço).
- PR que mistura mudanças de mais de um escopo força um título artificial
  (era o caso do PR #1, que juntou a Fase 1 com este ADR). Nos próximos PRs,
  preferir um escopo por PR quando o trabalho permitir.

## Alternativas consideradas

- **Sem enforcement automático, só documentação**: descartado — com dois
  contribuidores o padrão degrada rápido sem um hook cobrando.
- **commitlint sem escopo obrigatório**: descartado — o valor principal aqui
  é conseguir filtrar o histórico por área (`git log --grep '(db):'`), o que
  exige escopo sempre presente.
