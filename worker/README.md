# worker — Go 1.23

> ⚠️ **Bloqueado até a migration do role `worker_service` entrar em
> `supabase/`.** O código deste diretório está implementado e testado
> (`go build`, `go test`), mas o worker **não conecta em nenhum banco real
> hoje** — a credencial que ele espera em `WORKER_DATABASE_URL` (um role
> Postgres de login, com grants restritos a `photos`/`photo_faces`/`jobs` e
> `bypassrls`, decisão em [ADR 0011](../docs/adr/0011-worker-service-role.md))
> ainda não existe em nenhuma migration. **Essa migration é a próxima
> tarefa depois deste PR**, não um "algum dia" — sem ela, `go run
> ./cmd/worker` não tem para onde conectar.

Processo único que consome a fila `jobs` e fala com o serviço facial.
Go de propósito: serviço pequeno, isolado, sem risco para o resto do sistema.

```
cmd/worker/         main — carrega config de env vars, laço de polling
internal/jobs/       claim (FOR UPDATE SKIP LOCKED + lease de 10min), retry
                      exponencial, os três tipos de job
internal/faces/      cliente HTTP do services/face (POST /detect)
internal/storage/    R2 (S3-compatible): URL assinada de leitura, delete_objects
```

Tipos de job (docs/CONTRATO.md §4):

- **`index_faces`** `{photo_id}` — implementado.
- **`delete_objects`** `{keys}` — implementado no código; sem efeito em
  produção até o bucket R2 ser provisionado de verdade (`tofu apply` ainda
  não rodou — `docs/ESTADO.md`).
- **`purge_expired_embeddings`** `{}` — reconhecido, mas marcado como
  `skipped` (não `failed`, não retry) a cada execução. `ARQUITETURA.md` §12
  já propõe a regra ("1 ano após o evento"); o que falta não é o número, é a
  revisão jurídica que o próprio §12 lista como pendente do checklist LGPD.
  Implementar a exclusão antes dessa revisão fixaria em código uma decisão
  que ainda precisa de aval externo.

**Primeira trava de menores mora aqui:** foto com `contains_minors` verdadeiro
**ou nulo** é marcada como pulada e o serviço facial nunca é chamado —
a checagem roda antes até de assinar a URL de leitura do R2, não só antes de
chamar `/detect` (CLAUDE.md §3, ARQUITETURA.md §6,
[`internal/jobs/index_faces.go`](internal/jobs/index_faces.go)).

## Credencial de banco: role restrito, não `service_role`

O worker roda em loop, sem supervisão humana por requisição — categoria de
risco diferente de uma rota de servidor do galeria-web. Por isso ele **não**
usa a `service_role` key (bypass total de RLS, acesso a toda tabela do
schema). Ele conecta como `worker_service`, um role Postgres de login com
`bypassrls` mas grants explícitos só em `photos`/`photo_faces`/`jobs` — nada
em `profiles`, `guardians`, `minors`, `minor_consents`, `photo_grants`,
`face_consents`, `access_logs` ou `removal_requests`. Decisão completa e
grants exatos em [ADR 0011](../docs/adr/0011-worker-service-role.md).

A migration que cria esse role **não está neste PR** (escopo desta entrega é
só `worker/`) — é a próxima tarefa.

## Variáveis de ambiente

| Variável | Uso |
|---|---|
| `WORKER_DATABASE_URL` | connection string Postgres do role `worker_service` |
| `FACE_SERVICE_URL` | base URL de `services/face` (ex.: `https://face.fly.dev`) |
| `FACE_SERVICE_TOKEN` | valor do header `X-Service-Token` esperado pelo serviço facial |
| `R2_ACCOUNT_ID` | conta Cloudflare (monta o endpoint `https://<id>.r2.cloudflarestorage.com`) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | credencial S3-compatible do bucket — nunca via Tofu (`infra/README.md`), sempre `fly secrets set` |
| `R2_BUCKET` | nome do bucket |

Todas obrigatórias — o worker recusa subir sem alguma delas.

## Convenções

`gofmt`, erros embrulhados com `fmt.Errorf("...: %w", err)`, sem `panic` em
caminho normal. Nunca logar embedding, imagem, e-mail completo ou IP em
claro — `internal/faces` nunca loga corpo de request/response, e
`internal/jobs/runner.go` só loga `job_id`/`job_type`/`attempt`/erro.

## Comandos

```bash
cd worker && go build ./... && go test ./...
go run ./cmd/worker   # exige as env vars acima e o role worker_service já criado
```
