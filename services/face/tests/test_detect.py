from __future__ import annotations

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
