# 0013 — Migrations do Supabase só por workflow_dispatch, com dry-run antes

Status: accepted · Date: 2026-09-29

## Context

ADR 0012 já tinha corrigido o gatilho do job `migrations` (`ci.yml`) de
`main` (nunca existiu) para `master`, mas manteve o comportamento
automático: todo push em `master` disparava `supabase db push` sem
intervenção humana. Migration é a única categoria de mudança neste
projeto que altera schema em produção de forma imediata e sem o mesmo
tipo de rollback trivial que um `flyctl deploy` tem (reverter para a
imagem anterior) — uma migration ruim pode já ter corrompido dado antes
de alguém notar o CI vermelho.

## Decisão

- `migrations` deixa de ser job de `ci.yml` e vira workflow próprio,
  `.github/workflows/migrations.yml`, com gatilho **só**
  `workflow_dispatch` — nenhum `push`/`pull_request` aciona.
  `supabase db push` passa a exigir alguém abrir a aba Actions e clicar
  em "Run workflow", depois de já ter revisado o PR de release mesclado.
- Antes do `db push` de verdade, o job roda `supabase db push --dry-run`,
  que mostra o SQL que seria aplicado sem executar nada — chance de
  abortar (não dar `Run workflow` de novo) se o diff não for o esperado,
  antes de qualquer escrita no banco remoto.
- `ci.yml` não tem mais menção a migrations — o comentário de topo aponta
  para este ADR.

## Consequências

- Deploy dos apps Fly (`deploy.yml`, ADR 0012) continua automático em push
  para `master`; só migration ficou manual. As duas coisas já não
  compartilhavam falha/sucesso (ADR 0012); agora também não compartilham
  gatilho.
- Um push para `master` que inclua migration nova não aplica o schema
  sozinho — quem fizer o release precisa lembrar de rodar
  `migrations.yml` manualmente depois. Não há lembrete automático; se
  isso se mostrar fácil de esquecer na prática, revisar aqui.
- `supabase db push --dry-run` depende da CLI suportar a flag na versão
  fixada em `package.json`/`npx`; se uma versão futura remover ou renomear
  a flag, o step falha alto (antes do push real), não silenciosamente.

## Alternativas consideradas

- **Manter automático, só adicionar aprovação manual via `environment`
  protegido do GitHub**: resolveria o mesmo problema com um clique em vez
  de dois, mas exige configurar um Environment com required reviewers —
  passo de configuração fora do repositório (mesma categoria da ADR 0006).
  Descartado por agora a favor da opção mais simples (`workflow_dispatch`
  puro); revisar se o projeto ganhar mais de uma pessoa aplicando release.
