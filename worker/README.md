# worker — Go 1.23

Processo único que consome a fila `jobs` e fala com o serviço facial.
Go de propósito: serviço pequeno, isolado, sem risco para o resto do sistema.

```
cmd/worker/         main
internal/jobs/      claim (FOR UPDATE SKIP LOCKED), retry, tipos de job
internal/faces/     cliente HTTP do services/face
internal/storage/   R2: URL assinada de leitura, delete_objects
```

Tipos de job (docs/CONTRATO.md §4): `index_faces`, `delete_objects`,
`purge_expired_embeddings`.

**Primeira trava de menores mora aqui:** foto com `contains_minors` verdadeiro
**ou nulo** é marcada como pulada e o serviço facial nunca é chamado
(CLAUDE.md §3, ARQUITETURA.md §6).

Convenções: `gofmt`, erros embrulhados com `fmt.Errorf("...: %w", err)`, sem
`panic` em caminho normal. Nunca logar embedding, imagem, e-mail completo ou IP
em claro.

```bash
cd worker && go test ./... && go run ./cmd/worker
```
