# Como contribuir

Padrão de commits, branches e PRs deste repositório. Aplicado automaticamente
pelo husky (`commit-msg` e `pre-commit`) — commit fora do padrão é rejeitado
localmente, então isto aqui não é sugestão, é o que o hook cobra.

## Commits — Conventional Commits

```
<tipo>(<escopo>): <descrição no imperativo, minúsculo, sem ponto final>
```

**Tipos**: `feat` `fix` `docs` `style` `refactor` `perf` `test` `chore` `ci` `build` `revert`

**Escopos** (um por commit, sempre presente):

| Escopo | Área |
|---|---|
| `db` | `supabase/` — migrations, RLS, pgTAP |
| `worker` | `worker/` (Go) |
| `face` | `services/face/` (Python) |
| `infra` | `infra/` (OpenTofu) |
| `ci` | `.github/workflows` |
| `docs` | `docs/`, `CONTRIBUTING.md` |
| `deps` | `package.json` e dependências |
| `repo` | configuração geral do repositório |

Exemplos:

```
feat(db): adiciona tabela photos e policies de visibilidade
fix(worker): corrige retry exponencial do claim de job
docs(docs): atualiza fase 2 do roadmap em ARQUITETURA.md
ci(ci): adiciona job de tofu validate
```

Corpo do commit (opcional, linha em branco depois do subject) explica o
**porquê**, não o *o quê* — o diff já mostra o quê.

## Branches

```
<tipo>/<slug-em-kebab-case>
```

Mesmos tipos dos commits. O slug é curto e descreve o trabalho, não a fase
inteira do roadmap a menos que o PR seja mesmo a fase inteira.

```
feat/fase-2-fotos
fix/rls-photos-select
chore/husky-commitlint
```

`main`, `master` e `develop` são as únicas exceções ao padrão.

## Pull Requests

- **Título**: mesmo formato do commit — `tipo(escopo): descrição`. É o que
  vira changelog num squash merge.
- **Descrição**: usar o template em
  [.github/PULL_REQUEST_TEMPLATE.md](.github/PULL_REQUEST_TEMPLATE.md)
  (preenchido automaticamente ao abrir o PR no GitHub).
- PR que muda `supabase/migrations/` sem os testes pgTAP correspondentes, ou
  sem regenerar tipos para o `galeria-web` (docs/CONTRATO.md §2), não é
  mergeado.
- Referenciar a fase do roadmap (ARQUITETURA.md §13) quando aplicável.

## O que os hooks fazem

| Hook | Quando | O quê |
|---|---|---|
| `pre-commit` | todo commit | valida o nome da branch atual (`scripts/check-branch-name.sh`) |
| `commit-msg` | todo commit | valida a mensagem via `commitlint.config.js` |

Rodam via `husky`, instalado pelo script `prepare` do `package.json` — basta
`npm install` depois do clone.
