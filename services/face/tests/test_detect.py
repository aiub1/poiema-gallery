from __future__ import annotations

import cv2
import numpy as np
import pytest
import respx
from fastapi.testclient import TestClient
from httpx import Response

from tests.conftest import FakeFace, FakeFaceAnalysis, make_embedding

IMAGE_URL = "https://r2.example.com/signed/photo.webp"


@respx.mock
def test_detect_filters_by_min_quality(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    synthetic_image_bytes: bytes,
) -> None:
    respx.get(IMAGE_URL).mock(return_value=Response(200, content=synthetic_image_bytes))
    face_app_stub.faces = [
        FakeFace(normed_embedding=make_embedding(0.1), det_score=0.9),
        FakeFace(normed_embedding=make_embedding(0.2), det_score=0.3),
    ]

    response = client.post(
        "/detect",
        headers=auth_headers,
        json={"image_url": IMAGE_URL, "min_quality": 0.5},
    )

    assert response.status_code == 200
    faces = response.json()["faces"]
    assert len(faces) == 1
    assert faces[0]["quality"] == 0.9


@respx.mock
def test_detect_converts_bbox(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    synthetic_image_bytes: bytes,
) -> None:
    import numpy as np

    respx.get(IMAGE_URL).mock(return_value=Response(200, content=synthetic_image_bytes))
    face_app_stub.faces = [
        FakeFace(
            normed_embedding=make_embedding(),
            det_score=0.8,
            bbox=np.array([10.0, 20.0, 60.0, 100.0]),
        )
    ]

    response = client.post(
        "/detect",
        headers=auth_headers,
        json={"image_url": IMAGE_URL},
    )

    assert response.status_code == 200
    bbox = response.json()["faces"][0]["bbox"]
    assert bbox == {"x": 10.0, "y": 20.0, "w": 50.0, "h": 80.0}


@respx.mock
def test_detect_bbox_stays_in_original_scale_after_downscale(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FACE_MAX_SIDE", "100")

    # Imagem "grande" (400px do lado maior): com FACE_MAX_SIDE=100 o /detect
    # a reduz por scale=0.25 antes de chamar o modelo fake.
    large_image = np.zeros((200, 400, 3), dtype=np.uint8)
    ok, buffer = cv2.imencode(".png", large_image)
    assert ok
    respx.get(IMAGE_URL).mock(return_value=Response(200, content=buffer.tobytes()))

    # Bbox como o modelo devolveria rodando sobre a imagem já reduzida.
    face_app_stub.faces = [
        FakeFace(
            normed_embedding=make_embedding(),
            det_score=0.8,
            bbox=np.array([40.0, 40.0, 200.0, 240.0]),
        )
    ]

    response = client.post(
        "/detect",
        headers=auth_headers,
        json={"image_url": IMAGE_URL},
    )

    assert response.status_code == 200
    bbox = response.json()["faces"][0]["bbox"]
    # Coordenadas divididas pelo scale (0.25), de volta à escala original.
    assert bbox == {"x": 160.0, "y": 160.0, "w": 640.0, "h": 800.0}
