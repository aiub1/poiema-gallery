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

## Decisão 5 — `/metrics` exige `X-Service-Token`; coleta real ainda não resolvida (lacuna conhecida)

`GET /metrics` foi implementado exigindo `X-Service-Token`, por padrão mais
seguro (não expor contadores/latência publicamente). Mas quem efetivamente
lê esse endpoint não está decidido, e isso é uma lacuna real, não só
burocrática:

- `ARQUITETURA.md` §11 descreve **OpenTelemetry no worker e no serviço
  facial, exportando para Grafana Cloud** — um modelo **push** (o processo
  envia métricas via OTLP para fora), não um Prometheus fazendo *pull* em
  `/metrics`. Se essa for a rota adotada de fato, `/metrics` texto-Prometheus
  como está hoje (`prometheus_client.generate_latest()`) não é consumido por
  nada — vira um endpoint morto além de debug manual.
- Se em vez disso a intenção for um Prometheus/Grafana Agent fazendo scrape
  de `/metrics` (modelo pull, mais simples de operar no Fly.io que
  configurar exportação OTLP), o scraper precisa poder enviar
  `X-Service-Token` — viável (Grafana Agent/Alloy suportam headers
  customizados por job de scrape), mas exige provisionar esse token no
  scraper via Fly secrets, o que **não está feito nem desenhado**.
- Observabilidade real é trabalho da **Fase 5** (`ARQUITETURA.md` §13,
  "Acabamento") — checklist LGPD §12 também lista "nenhum log com
  embedding/selfie/IP" como pendente de revisão formal, não só código.

**Decisão explícita, não implícita:** `/metrics` fica exigindo token e
implementado no formato Prometheus por ora (menor esforço, reversível), mas
**nenhum scraper está configurado** — hoje o endpoint só serve para curl
manual com o token. Antes de a Fase 5 depender dele, decidir entre (a)
provisionar um scraper interno autenticado, ou (b) substituir por
exportação OTel push conforme §11 e reduzir `/metrics` a um endpoint de
diagnóstico manual.

## Decisão 6 — imagem de teste real revelou tamanho e um bug não previstos; `insightface` instalado com `--no-deps`

Etapa 1 estimou o modelo em ~280 MB e um acréscimo de "300-400 MB" na
imagem pelo empacotamento. O primeiro build real (`docker build`, imagem
completa) mediu **894 MB comprimida / 2,59 GB descomprimida**, bem acima
disso, por duas causas concretas (`docker history` + inspeção do pacote
instalado):

1. **O pacote `buffalo_l` completo é ~630 MB**, não ~280 MB — a estimativa
   original era só o arquivo de reconhecimento (`w600k_r50.onnx`); o pacote
   real traz também detecção, landmarks 3D, landmarks 2D e gênero/idade.
2. **`insightface` declara uma árvore de dependências que o código nunca
   usa**: `matplotlib`, `scipy`, `albumentations`, `scikit-learn`,
   `prettytable`, `easydict` (~926 MB no `site-packages`). Rastreando os
   imports reais do pacote (não a documentação): `insightface/__init__.py`
   importa `app` incondicionalmente; `insightface/app/__init__.py` faz
   `from .mask_renderer import *`; `mask_renderer.py` é quem importa
   `albumentations` e `insightface.thirdparty.face3d` (que por sua vez
   importa `matplotlib`/`scipy`). Este serviço **nunca instancia
   `MaskRenderer`** — só usa `FaceAnalysis` para detecção e embedding.
   `scikit-learn`/`prettytable`/`easydict` não têm nenhum import ativo em
   lugar nenhum do pacote (confirmado por busca no código-fonte instalado)
   — são peso morto do `install_requires` do `insightface`, nunca
   executado.

Solução, validada rodando o `Dockerfile` de ponta a ponta:

- `main.py`/`Dockerfile` instalam `insightface` com **`--no-deps`**, e
  `requirements.txt` declara explicitamente as dependências que o pacote
  de fato usa em runtime: `onnx` (`model_zoo.py`, `numpy_helper`),
  `scikit-image` (`utils/face_align.py`, `utils/transform.py` — alinhamento
  do rosto recortado antes do ArcFace), `requests` e `tqdm`
  (`utils/download.py` — baixa modelo sob demanda; não é o caminho usado
  aqui, que baixa em build-time, mas o módulo precisa importar sem erro).
- O `Dockerfile` remove, via `sed`, a linha `from .mask_renderer import *`
  de `insightface/app/__init__.py` instalado — sem isso, `import
  insightface` quebraria com `ModuleNotFoundError: No module named
  'albumentations'`, já que ele não é mais instalado.
- A versão do `insightface` pinada é lida do próprio `requirements.txt`
  (`grep '^insightface=='`), não duplicada no `Dockerfile` — evita que os
  dois arquivos fiquem dessincronizados num bump futuro.

Risco assumido, no mesmo espírito da Decisão 2: um patch `sed` sobre um
arquivo interno de um pacote de terceiros não é uma API estável. Se um
upgrade de `insightface` mudar essa linha, o `sed` não casa nada
silenciosamente e o build volta a puxar `albumentations`/`matplotlib` (o
teste de smoke manual, não o CI, é quem detectaria isso — ver nota em
"Consequências"). `requirements-dev.txt`/uso local (`pip install -r
requirements.txt`) continuam instalando `insightface` com deps completas —
o `--no-deps` é só do `Dockerfile`, para não complicar o fluxo de
desenvolvimento local por causa do tamanho da imagem de produção.

**Bug não previsto, encontrado no mesmo smoke test:** o usuário `face`
(não-root) não tem `$HOME` gravável, e `matplotlib` (antes de ser
removido) tentava criar `~/.config/matplotlib` e falhava com
`PermissionError`, caindo para `/tmp` sozinho — não fatal, mas sujava o
log a cada cold start. Corrigido de duas formas: a causa raiz some com a
remoção de `matplotlib` (decisão acima), e `ENV MPLCONFIGDIR=/tmp` fica
como defesa em profundidade caso alguma dependência futura reintroduza
`matplotlib`.

**Resultado medido após a mudança** (`docker build` real rodado de novo,
`docker history` como fonte — mais confiável que os campos agregados do
`docker images`, que variaram de forma inconsistente entre as duas
builds): camada `COPY /install /usr/local` caiu de **926 MB para 744 MB**
(-182 MB, -20%); camada do modelo (`COPY .../models`) ficou igual, 630 MB
— é o pacote `buffalo_l` completo, não há como reduzir sem parar de usar
landmark 3D/gênero-idade, fora do escopo desta decisão. Conteúdo bruto
total (soma de camadas) foi de ~1,66 GB para ~1,47 GB, uma redução real de
~11%. Menor do que os ~500 MB de pacotes removidos sugeririam à primeira
vista, porque parte do peso comprime bem (código-fonte Python) e parte não
(bibliotecas binárias `.so`); a `onnx`/`scikit-image` adicionadas de volta
também tomam espaço. Smoke test manual (container real, modelo real,
`SERVICE_TOKEN` real) confirmou depois da mudança: `/health` e `/embed`
respondendo corretamente (`/embed` com imagem sintética sem rosto real
→ `422 no_face_detected`, como esperado), cold start caiu de ~16,6 s para
~5 s (menos import de `matplotlib`/`scipy` no startup), e o erro de
permissão do matplotlib sumiu dos logs. `/detect` foi validado uma vez,
com sucesso, antes desta mudança (200, filtro de `min_quality` correto);
não foi possível revalidar via URL depois, por limitação de rede do
ambiente de sandbox usado para o teste (container não alcançava um
servidor HTTP auxiliar no host) — não é uma limitação do serviço, e o
código de `/detect` não mudou nesta decisão.

## Consequências

- `GET /metrics` exige `X-Service-Token`, embora `CONTRATO.md` §3 não
  especificasse — decisão tomada nesta fase (mais seguro por padrão).
  Se isso divergir do que `galeria-web`/observabilidade externa esperam,
  revisar aqui antes de mudar. **Coleta real ainda não resolvida — ver
  Decisão 5.**
- Job `face-service` do CI (`.github/workflows/ci.yml`) roda `ruff`,
  `mypy` e `pytest`, deixando de ser no-op.
- Se a Decisão 2 quebrar num upgrade futuro de Starlette (o teste de
  não-persistência pega isso), reavaliar se vale migrar para um parser
  multipart próprio em vez de depender do atributo interno.
- Se um upgrade de `insightface` mudar `app/__init__.py` e o `sed` da
  Decisão 6 parar de casar, o build volta a instalar
  `matplotlib`/`albumentations`/`scipy` sem avisar — nenhum teste
  automatizado pega isso hoje (é um patch sobre a imagem Docker, fora do
  que `pytest`/CI cobrem). Quem fizer o bump deve rodar `docker build` e
  conferir `docker history`/tamanho antes de mergear.
