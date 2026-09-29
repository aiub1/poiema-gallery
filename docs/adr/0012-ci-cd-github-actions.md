# 0012 — CI/CD no GitHub Actions, separado de deploy

Status: accepted · Date: 2026-09-29

## Context

`worker/` e `services/face/` já têm `Dockerfile` e `fly.toml` próprios
(ADR 0011, ADR 0010), mas o deploy nos apps Fly (`poiema-gallery-face`,
`poiema-gallery-workerr`) ainda era manual. `.github/workflows/ci.yml`
já existia com jobs de teste (`database`, `worker`, `face-service`,
`infra`) e um job `deploy` esqueleto, mas com dois problemas encontrados
ao implementar esta ADR:

- O gatilho apontava para uma branch `main`, que nunca existiu neste
  repositório. O remoto real tem `master` (só o commit inicial, quase
  vazio) e `develop` (onde todo o código e os PRs de fato acontecem —
  #11, #12 foram mesclados em `develop`, não em `master`).
- O job `deploy` misturava duas responsabilidades sem relação de causa
  entre si — push de migrations do Supabase e deploy dos apps Fly — sob
  a mesma condição (`infra/*.tf` existir), o que faria um bug de migration
  bloquear deploy de app e vice-versa sem necessidade.

## Decisão

### Branches: `develop` = integração, `master` = produção

- `develop` é o destino usual de PR de feature/fix — onde os testes
  (`ci.yml`) rodam a cada PR.
- `master` só recebe PR de release (`develop` → `master`). É o gatilho de
  deploy (`deploy.yml`) e de push de migrations (`ci.yml`, job
  `migrations`).
- `ci.yml` roda em `pull_request` para **ambas** (`develop` e `master`) —
  um PR de release passa pelos mesmos testes antes de ir para produção.
- Esta ADR não decide *quando* abrir o PR de release; só fixa que o
  caminho para produção passa por PR para `master`, nunca push direto.

### CI (`ci.yml`) — job `changes` com `dorny/paths-filter`

`worker` e `face-service` só rodam de verdade quando a pasta
correspondente mudou. A alternativa óbvia — `paths:` no gatilho do
workflow — foi descartada: quando o workflow inteiro não dispara para um
PR (porque nenhum arquivo bate com o filtro), o check nomeado nunca é
reportado, e branch protection com "require status checks" trava esperando
um check que nunca chega. Com `dorny/paths-filter` + `if:` a nível de job,
o job sempre roda (mesmo que só para decidir que não faz nada) e reporta
**skipped** — que GitHub Actions conta como sucesso para status check
obrigatório. `database`, `infra` e `pr-title` continuam sem esse filtro:
já tinham sua própria guarda (`hashFiles`) ou sempre fazem sentido rodar.

### Deploy (`deploy.yml`) — arquivo separado de `ci.yml`

- Um job por app (`deploy-face`, `deploy-worker`), cada um só dispara
  quando a pasta correspondente mudou no push para `master` (mesmo
  `changes` via `paths-filter`) — ou por `workflow_dispatch` manual, com
  input `app` (`both`/`face`/`worker`) para redeploy independente de push.
- **Tokens por app**: `FLY_TOKEN_FACE` e `FLY_TOKEN_WORKER`, cada um
  injetado só no `env` do step de deploy do respectivo job — nunca um
  token com acesso aos dois apps. Um token comprometido (log vazado,
  dependência de step maliciosa) limita o dano ao app correspondente,
  não aos dois.
- **`concurrency` por app** (`group: deploy-face` / `deploy-worker`,
  `cancel-in-progress: false`): dois pushes rápidos para `master` não
  disparam dois `flyctl deploy` simultâneos no mesmo app — o segundo
  espera o primeiro terminar, em vez de cancelar (um deploy cancelado no
  meio é peor que um atrasado).
- **`--local-only --ha=false`**: `--local-only` builda a imagem na própria
  máquina do runner em vez de depender do builder remoto do Fly (menos uma
  dependência externa, runner já paga o custo de build no CI de qualquer
  forma); `--ha=false` evita que o Fly tente manter 2 máquinas em paralelo
  durante o rollout — ambos os apps rodam `min_machines_running = 0`
  (`fly.toml`), então alta disponibilidade não é o objetivo aqui, e manter
  2 máquinas rodando por engano custaria mais sem benefício.
- **Smoke test só do `face`**: depois do deploy, `curl` com retry (10
  tentativas, 3s de intervalo — até ~30s) em `/health` esperando `200`,
  tolerando o cold start do free tier (mesma característica documentada no
  `Dockerfile` do serviço). O worker não expõe HTTP público (só métricas
  internas ao processo), então não há endpoint equivalente para smoke test
  aqui.
- **Migrations do Supabase ficam fora deste workflow.** O push de
  migrations (`npx supabase db push`) já existia no job `deploy` antigo
  de `ci.yml`; foi movido para um job próprio (`migrations`, ainda em
  `ci.yml`, gatilho corrigido de `main` para `master`) em vez de para
  `deploy.yml`, porque as duas coisas não têm razão para falhar ou ter
  sucesso juntas: uma migration com problema não deveria bloquear deploy
  de app (nem o contrário). Nenhuma lógica de migration foi alterada
  nesta ADR — só o gatilho de branch.
- **Actions fixadas por SHA de commit**, não por tag (comentário ao lado
  com a versão correspondente) — tag é mutável; quem controla o repositório
  da action pode apontar a mesma tag para outro commit depois que o job já
  está em produção. Aplica-se só aos arquivos tocados nesta ADR
  (`ci.yml`: job `changes`, `worker`, `face-service`; `deploy.yml` inteiro).
  Os demais jobs de `ci.yml` (`pr-title`, `database`, `infra`, `migrations`)
  não foram tocados e mantêm a convenção anterior (tag), fora do escopo
  desta mudança.
- `permissions: contents: read` no topo de `deploy.yml` — nenhum job
  precisa de escrita no repositório (deploy usa `FLY_API_TOKEN`, não
  `GITHUB_TOKEN`).

## Consequências

- `FLY_TOKEN_FACE` e `FLY_TOKEN_WORKER` precisam existir como secrets do
  repositório antes do primeiro push para `master` que toque
  `services/face/` ou `worker/` — sem eles, o job de deploy falha na
  autenticação do `flyctl`. Passo manual, fora deste PR.
- Branch protection de `master`/`develop` precisa listar os nomes de job
  corretos (`changes`, `worker`, `face-service`, etc.) como status check
  obrigatório — nomes de job, não de workflow.
- Se um dia `services/face/` ou `worker/` ganhar mais de um app Fly (ex.:
  staging), este desenho (um job de deploy por app, token por app) escala
  sem redesenho — só adicionar mais um job.
- `commitlint.config.js`/`ci.yml` (job `pr-title`) já tinham o escopo
  `ci`; nenhuma mudança necessária ali.

## Alternativas consideradas

- **`paths:` no gatilho do workflow em vez de `dorny/paths-filter` + `if:`
  de job**: mais simples, mas quebra branch protection quando a pasta não
  muda (check nunca reportado) — descartada, ver acima.
- **Um único job de deploy fazendo os dois apps em sequência**: mais
  simples de ler, mas um `flyctl deploy` do face travado bloquearia o
  deploy do worker mesmo sem relação entre os dois — descartada a favor de
  dois jobs independentes, que também paralelizam.
- **Migrations dentro de `deploy.yml`**: descartado — ver decisão acima
  sobre não acoplar migration e deploy de app à mesma falha/sucesso.
