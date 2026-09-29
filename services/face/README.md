# services/face — Python 3.12 + FastAPI + InsightFace

Detecta rostos e gera embeddings. Roda no Fly.io, CPU basta.
**Só o servidor chama** — nunca exposto ao navegador. Auth por `X-Service-Token`.

```
main.py            FastAPI: /detect, /embed, /health, /metrics
download_model.py  baixa o buffalo_l — só em build-time (Dockerfile), nunca em runtime
requirements.txt   dependências de produção, versões fixadas
requirements-dev.txt  + pytest, ruff, mypy, respx
tests/             pytest
```

Contrato completo em `docs/CONTRATO.md` §3.

## Variáveis de ambiente

| Variável | Obrigatória | Padrão | Uso |
|---|---|---|---|
| `SERVICE_TOKEN` | sim | — | valor esperado no header `X-Service-Token` |
| `FACE_MODEL_ROOT` | não | `/opt/insightface/models` | onde o InsightFace procura os pesos do `buffalo_l` |
| `FACE_DET_SIZE` | não | `640` | tamanho (px, quadrado) do detector |
| `MAX_UPLOAD_BYTES` | não | `15728640` (15 MB) | teto de tamanho do arquivo em `/embed` |

## Modelo: empacotado na imagem, não baixado em runtime

O pacote `buffalo_l` completo (detecção + landmarks 3D/2D + gênero/idade +
reconhecimento) tem ~630 MB — medido no build real, não estimado. Baixar
no primeiro uso é mais leve no repositório, mas o free tier do Fly.io
hiberna a máquina por inatividade — todo cold start pagaria rede + disco
de novo. Por isso o `Dockerfile` baixa o modelo em build-time
(`download_model.py`, roda uma vez, no builder stage) e a imagem final só
carrega pesos já em disco local.

`insightface` é instalado com `--no-deps` no `Dockerfile` — a versão
normal do pacote traz `matplotlib`/`scipy`/`albumentations`/`scikit-learn`
que o serviço nunca usa (só existem por causa do `MaskRenderer`, nunca
chamado aqui). Ver [ADR 0010](../../docs/adr/0010-face-service-implementation.md),
decisão 6, para a investigação completa e os números medidos antes/depois.

**O modelo nunca é commitado no git** — `download_model.py` só roda dentro
do build da imagem Docker.

## Garantia de não-persistência (`/embed` e `/detect`)

CLAUDE.md §5.2: embedding facial é dado pessoal sensível, tratado como
senha. `ARQUITETURA.md` §7 exige que `/embed` rode inteiramente em memória.

Dois problemas reais, não óbvios, resolvidos aqui:

1. **`UploadFile` do Starlette grava em disco acima de 1 MB por padrão**
   (`SpooledTemporaryFile` transborda para um arquivo real). A versão
   fixada de Starlette não expõe esse limite via `Request.form()`, então
   `main.py` eleva `MultiPartParser.max_file_size` para o teto configurado
   em `MAX_UPLOAD_BYTES` — como o `Content-Length` já foi checado antes,
   o arquivo nunca ultrapassa esse teto e o buffer nunca sai da memória.
2. **Log de acesso do uvicorn loga IP do cliente em claro** (proibido por
   CLAUDE.md §5.2) — por isso o `Dockerfile` roda com `--no-access-log`.

Testado em `tests/test_embed.py::test_embed_never_writes_to_disk`: o teste
substitui `tempfile.NamedTemporaryFile`/`mkstemp`/`TemporaryFile`/`mkdtemp`
por stubs que derrubam o teste se forem chamados, **e** compara o conteúdo
de `tempfile.gettempdir()` e do diretório de trabalho antes/depois da
chamada — cobre tanto escrita direta quanto qualquer escrita indireta que
escape do monkeypatch.

`tests/test_embed.py::test_embed_does_not_log_embedding_or_filename` prova
que nem o embedding, nem o nome do arquivo, nem o token aparecem em log
capturado durante a chamada — não basta a ausência de um `logger.info(...)`
explícito, uma regressão futura precisa falhar o teste.

## Testes offline, sem modelo real

Os testes **não** carregam o InsightFace de verdade — `tests/conftest.py`
substitui a dependência `get_face_app` por um stub (`FakeFaceAnalysis`) via
`app.dependency_overrides`. Isso mantém o CI rápido e sem rede, e é
justamente por isso que o `main.py` só importa `insightface` dentro de
`_build_face_app`, nunca no topo do módulo.

`/detect` é testado com `respx` mockando a URL assinada — nenhuma rede real.

Imagens de teste são sintéticas (geradas em memória com numpy/cv2),
**nunca** uma foto real.

## Comandos

```bash
cd services/face
pip install -r requirements-dev.txt
export SERVICE_TOKEN=dev-token

uvicorn main:app --reload
ruff check .
mypy main.py
pytest
```

Convenções: `ruff` + `mypy` (`strict = true`), tipagem explícita nos
handlers (`CLAUDE.md` §6).

InsightFace `buffalo_l`, 512 dimensões, L2-normalizado (`normed_embedding`).
Limiar cosseno `< 0.38` como ponto de partida — **calibrar com fotos reais
do primeiro evento**. Falso positivo (devolver estranho) é muito pior que
falso negativo.
