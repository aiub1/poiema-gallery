"""Serviço facial — detecção e embedding via InsightFace.

Contrato completo em docs/CONTRATO.md §3. Invariantes de privacidade em
CLAUDE.md §5.2: nada é persistido em disco, nenhuma resposta expõe o vetor
de embedding além do retorno legítimo ao servidor chamador, e nada de
embedding/imagem/e-mail/IP é logado em claro.
"""

from __future__ import annotations

import hmac
import os
from dataclasses import dataclass
from typing import Any

import cv2
import httpx
import numpy as np
import numpy.typing as npt
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel, HttpUrl
from starlette.datastructures import UploadFile as StarletteUploadFile
from starlette.formparsers import MultiPartParser as _MultiPartParser
from starlette.responses import Response

app = FastAPI(title="galeria-core face service")

REQUEST_COUNT = Counter(
    "face_service_requests_total", "Total de requisições", ["path", "status"]
)
REQUEST_LATENCY = Histogram(
    "face_service_request_duration_seconds", "Duração da requisição", ["path"]
)


@dataclass(frozen=True)
class Settings:
    service_token: str
    model_root: str
    det_size: int
    max_upload_bytes: int
    face_max_side: int


def get_settings() -> Settings:
    token = os.environ.get("SERVICE_TOKEN")
    if not token:
        raise RuntimeError("SERVICE_TOKEN não configurado")
    return Settings(
        service_token=token,
        model_root=os.environ.get("FACE_MODEL_ROOT", "/opt/insightface/models"),
        det_size=int(os.environ.get("FACE_DET_SIZE", "640")),
        max_upload_bytes=int(os.environ.get("MAX_UPLOAD_BYTES", str(15 * 1024 * 1024))),
        face_max_side=int(os.environ.get("FACE_MAX_SIDE", "1600")),
    )


class BBox(BaseModel):
    x: float
    y: float
    w: float
    h: float


class Face(BaseModel):
    embedding: list[float]
    bbox: BBox
    quality: float


class DetectRequest(BaseModel):
    image_url: HttpUrl
    min_quality: float = 0.5


class DetectResponse(BaseModel):
    faces: list[Face]


class EmbedResponse(BaseModel):
    embedding: list[float]
    quality: float


async def require_service_token(
    x_service_token: str | None = Header(default=None, alias="X-Service-Token"),
) -> None:
    settings = get_settings()
    if not x_service_token or not hmac.compare_digest(x_service_token, settings.service_token):
        raise HTTPException(
            status_code=401,
            detail={
                "error": {
                    "code": "unauthorized",
                    "message": "token de serviço ausente ou inválido",
                }
            },
        )


def _build_face_app(settings: Settings) -> Any:
    # Import adiado: instanciar isso importa o InsightFace inteiro, que só é
    # necessário em produção. Testes substituem get_face_app via
    # app.dependency_overrides e nunca chegam aqui.
    from insightface.app import FaceAnalysis

    # Só usamos detecção e reconhecimento. Os demais modelos do pacote
    # buffalo_l (landmarks 2D/3D, gênero/idade) rodam por rosto e custam
    # tempo e memória à toa — e produziriam inferências sobre a pessoa que
    # este sistema não usa e não pode guardar (CLAUDE.md §5.2).
    face_app = FaceAnalysis(
        name="buffalo_l",
        root=settings.model_root,
        allowed_modules=["detection", "recognition"],
    )
    face_app.prepare(ctx_id=-1, det_size=(settings.det_size, settings.det_size))
    return face_app


async def get_face_app(request: Request) -> Any:
    # Carregado sob demanda, uma vez por processo — não no startup, para que
    # os testes possam sobrescrever esta dependência sem baixar o modelo real.
    if getattr(request.app.state, "face_app", None) is None:
        request.app.state.face_app = _build_face_app(get_settings())
    return request.app.state.face_app


def decode_image(data: bytes) -> npt.NDArray[np.uint8]:
    array = np.frombuffer(data, dtype=np.uint8)
    image = cv2.imdecode(array, cv2.IMREAD_COLOR)
    if image is None:
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "invalid_image",
                    "message": "não foi possível decodificar a imagem",
                }
            },
        )
    return image.astype(np.uint8)


def downscale(
    image: npt.NDArray[np.uint8], max_side: int
) -> tuple[npt.NDArray[np.uint8], float]:
    height, width = image.shape[:2]
    scale = min(1.0, max_side / max(height, width))
    if scale >= 1.0:
        return image, 1.0
    resized = cv2.resize(
        image,
        (round(width * scale), round(height * scale)),
        interpolation=cv2.INTER_AREA,
    )
    return resized.astype(np.uint8), scale


def _bbox_from_array(bbox: npt.NDArray[np.float32], scale: float = 1.0) -> BBox:
    x1, y1, x2, y2 = (float(v) / scale for v in bbox)
    return BBox(x=x1, y=y1, w=x2 - x1, h=y2 - y1)


async def _fetch_image(url: str) -> bytes:
    async with httpx.AsyncClient(timeout=10.0) as client:
        response = await client.get(url)
        response.raise_for_status()
        return response.content


@app.middleware("http")
async def metrics_middleware(request: Request, call_next: Any) -> Response:
    with REQUEST_LATENCY.labels(path=request.url.path).time():
        response = await call_next(request)
    REQUEST_COUNT.labels(path=request.url.path, status=response.status_code).inc()
    return response  # type: ignore[no-any-return]


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/metrics", dependencies=[Depends(require_service_token)])
async def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/detect", response_model=DetectResponse, dependencies=[Depends(require_service_token)])
async def detect(payload: DetectRequest, face_app: Any = Depends(get_face_app)) -> DetectResponse:
    settings = get_settings()
    image_bytes = await _fetch_image(str(payload.image_url))
    image = decode_image(image_bytes)
    image, scale = downscale(image, settings.face_max_side)
    faces = face_app.get(image)
    detected = [
        Face(
            embedding=face.normed_embedding.tolist(),
            bbox=_bbox_from_array(face.bbox, scale),
            quality=float(face.det_score),
        )
        for face in faces
        if float(face.det_score) >= payload.min_quality
    ]
    return DetectResponse(faces=detected)


@app.post("/embed", response_model=EmbedResponse, dependencies=[Depends(require_service_token)])
async def embed(request: Request, face_app: Any = Depends(get_face_app)) -> EmbedResponse:
    settings = get_settings()

    content_length = int(request.headers.get("content-length", 0))
    if content_length > settings.max_upload_bytes:
        raise HTTPException(
            status_code=413,
            detail={
                "error": {
                    "code": "payload_too_large",
                    "message": "arquivo excede o limite permitido",
                }
            },
        )

    # O Starlette faz o UploadFile transbordar para um arquivo real em disco
    # (SpooledTemporaryFile) acima de 1 MB por padrão, e a versão fixada
    # aqui não expõe esse limite via Request.form(). Elevamos o teto da
    # classe para o limite configurado: como o content-length já foi
    # checado acima, o arquivo nunca ultrapassa esse teto e o
    # SpooledTemporaryFile nunca sai da memória.
    _MultiPartParser.max_file_size = settings.max_upload_bytes
    form = await request.form()
    upload = form.get("file")
    if not isinstance(upload, StarletteUploadFile):
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "missing_file",
                    "message": "campo 'file' ausente",
                }
            },
        )

    data = await upload.read()
    image = decode_image(data)
    image, _scale = downscale(image, settings.face_max_side)
    faces = face_app.get(image)
    if not faces:
        raise HTTPException(
            status_code=422,
            detail={
                "error": {
                    "code": "no_face_detected",
                    "message": "nenhum rosto detectado na imagem",
                }
            },
        )

    best = max(faces, key=lambda f: float(f.det_score))
    return EmbedResponse(embedding=best.normed_embedding.tolist(), quality=float(best.det_score))
