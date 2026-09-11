# syntax=docker/dockerfile:1
FROM python:3.12-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
ENV FACE_MODEL_ROOT=/opt/insightface/models

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Baixa o modelo em build-time (§ etapa 2 do plano) — cold start no free
# tier do Fly não paga rede + disco, só carregamento do onnxruntime.
ENV PYTHONPATH=/install/lib/python3.12/site-packages
COPY download_model.py .
RUN python download_model.py

FROM python:3.12-slim

RUN groupadd --system face && useradd --system --gid face face

COPY --from=builder /install /usr/local
COPY --from=builder /opt/insightface/models /opt/insightface/models
WORKDIR /app
COPY main.py .

ENV FACE_MODEL_ROOT=/opt/insightface/models
USER face
EXPOSE 8000

# --no-access-log: o log padrão do uvicorn inclui o IP do cliente em claro,
# proibido por CLAUDE.md §5.2.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
