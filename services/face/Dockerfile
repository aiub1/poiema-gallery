# syntax=docker/dockerfile:1
FROM python:3.12-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENV FACE_MODEL_ROOT=/opt/insightface/models

COPY requirements.txt .

# insightface instalado à parte, com --no-deps: pip install -r
# requirements.txt puxaria matplotlib/scipy/albumentations/scikit-learn/
# prettytable/easydict — nada disso é usado (só existem por causa do
# MaskRenderer, que este serviço nunca chama). As dependências reais de
# runtime do insightface (onnx, scikit-image, requests, tqdm) estão
# listadas em requirements.txt. Ver ADR 0010, decisão 6.
RUN grep '^insightface==' requirements.txt > insightface.txt \
    && grep -v '^insightface==' requirements.txt > requirements.runtime.txt \
    && pip install --no-cache-dir --prefix=/install -r requirements.runtime.txt \
    && pip install --no-cache-dir --no-deps --prefix=/install -r insightface.txt

ENV PYTHONPATH=/install/lib/python3.12/site-packages

# Remove o import forçado do MaskRenderer em insightface/app/__init__.py —
# é o que puxava matplotlib/albumentations/scipy antes do --no-deps acima;
# sem essa linha, "import insightface" nunca toca esses módulos. Patch de
# um pacote de terceiros: se um upgrade futuro de insightface mudar essa
# linha, este sed simplesmente não casa nada (comportamento silencioso,
# não quebra o build) — checar manualmente após qualquer bump de versão.
RUN sed -i '/from \.mask_renderer import \*/d' \
      /install/lib/python3.12/site-packages/insightface/app/__init__.py

# Baixa o modelo em build-time (§ etapa 2 do plano) — cold start no free
# tier do Fly não paga rede + disco, só carregamento do onnxruntime.
COPY download_model.py .
RUN python download_model.py

FROM python:3.12-slim

RUN groupadd --system face && useradd --system --gid face face

COPY --from=builder /install /usr/local
COPY --from=builder /opt/insightface/models /opt/insightface/models
WORKDIR /app
COPY main.py .

ENV FACE_MODEL_ROOT=/opt/insightface/models
# Defesa em profundidade: se alguma dependência futura reintroduzir
# matplotlib, ele tenta gravar cache em $HOME/.config — o usuário 'face'
# não tem HOME gravável (achado no smoke test manual desta fase).
ENV MPLCONFIGDIR=/tmp
USER face
EXPOSE 8000

# --no-access-log: o log padrão do uvicorn inclui o IP do cliente em claro,
# proibido por CLAUDE.md §5.2.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
