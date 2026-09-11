# 0010 — Implementação do serviço facial (fase 4b)

Status: accepted · Date: 2026-09-11

## Context

Implementação de `services/face/`: `/detect`, `/embed`, `/health`,
`/metrics` (`CONTRATO.md` §3). Três decisões não cobertas por
`ARQUITETURA.md` nem `CONTRATO.md` surgiram na implementação.

## Decisão 1 — Modelo `buffalo_l` empacotado na imagem Docker

`ARQUITETURA.md` §14 documenta que o free tier do Fly.io hiberna a máquina
por inatividade — uso esperado é baixo (igreja, tráfego esparso), então
cold start é a norma, não a exceção. Baixar o modelo (~280 MB) no primeiro
uso pagaria rede + disco a cada religada. `Dockerfile` baixa o modelo em
build-time (`download_model.py`, builder stage) para `FACE_MODEL_ROOT`
(`/opt/insightface/models`); a imagem final só carrega pesos já em disco
local. Trade-off aceito: imagem ~300-400 MB maior, build mais lento.

## Decisão 2 — `/embed` eleva `MultiPartParser.max_file_size` em vez de usar `Request.form()` diretamente

`ARQUITETURA.md` §7 exige `/embed` inteiramente em memória. O `UploadFile`
do Starlette usa `SpooledTemporaryFile(max_size=1 MB)` — acima de 1 MB, ele
**grava em disco de verdade**. A versão de Starlette fixada em
`requirements.txt` (0.41.3) não expõe esse limite como parâmetro de
`Request.form()` (checado lendo o código-fonte instalado, não documentação
— a assinatura pública só aceita `max_files`/`max_fields`). Selfies reais
costumam passar de 1 MB.

Solução: `main.py` eleva o atributo de classe
`starlette.formparsers.MultiPartParser.max_file_size` para
`MAX_UPLOAD_BYTES` antes de chamar `request.form()`, dentro do handler de
`/embed`, depois de já ter rejeitado (413) qualquer requisição cujo
`Content-Length` exceda esse mesmo teto. Como o arquivo nunca ultrapassa o
teto, o `SpooledTemporaryFile` nunca sai da memória — sem reescrever o
parser multipart à mão, o que seria mais código e mais risco de bug sutil
do que ajustar um atributo de uma classe já testada pela própria Starlette.

Risco assumido: esse é um detalhe de implementação de uma versão específica
de Starlette, não uma API pública estável. Um upgrade de Starlette pode
mudar esse comportamento silenciosamente. Mitigado pelo teste
`test_embed_never_writes_to_disk`, que falha se qualquer escrita em disco
acontecer, independentemente do mecanismo interno.

## Decisão 3 — `--no-access-log` no uvicorn

O log de acesso padrão do uvicorn inclui o IP do cliente
(`%(client_addr)s`), proibido em claro por `CLAUDE.md` §5.2. `Dockerfile`
roda `uvicorn ... --no-access-log`. Observabilidade de requisições fica só
com `/metrics` (contadores/latência por rota, sem IP nem payload).

## Decisão 4 — testes não carregam o InsightFace real

`main.py` só importa `insightface` dentro de `_build_face_app`
(import adiado), nunca no topo do módulo. A dependência `get_face_app` é
sobrescrita nos testes via `app.dependency_overrides` por um stub
(`FakeFaceAnalysis`) que nunca baixa nem carrega o modelo — CI fica rápido
e sem rede. `/detect` é testado com `respx` mockando a URL assinada.

## Consequências

- `GET /metrics` exige `X-Service-Token`, embora `CONTRATO.md` §3 não
  especificasse — decisão tomada nesta fase (mais seguro por padrão).
  Se isso divergir do que `galeria-web`/observabilidade externa esperam,
  revisar aqui antes de mudar.
- Job `face-service` do CI (`.github/workflows/ci.yml`) roda `ruff`,
  `mypy` e `pytest`, deixando de ser no-op.
- Se a Decisão 2 quebrar num upgrade futuro de Starlette (o teste de
  não-persistência pega isso), reavaliar se vale migrar para um parser
  multipart próprio em vez de depender do atributo interno.
