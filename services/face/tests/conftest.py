from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

import main

TEST_TOKEN = "test-service-token"


@dataclass
class FakeFace:
    normed_embedding: np.ndarray
    det_score: float
    bbox: np.ndarray = field(default_factory=lambda: np.array([10.0, 10.0, 100.0, 100.0]))


class FakeFaceAnalysis:
    """Substitui o InsightFace real nos testes — sem modelo, sem rede."""

    def __init__(self) -> None:
        self.faces: list[FakeFace] = []

    def get(self, image: np.ndarray) -> list[FakeFace]:
        return self.faces


def make_embedding(seed: float = 0.1) -> np.ndarray:
    vec = np.full(512, seed, dtype=np.float32)
    return vec / np.linalg.norm(vec)


@pytest.fixture
def face_app_stub() -> FakeFaceAnalysis:
    return FakeFaceAnalysis()


@pytest.fixture
def client(
    monkeypatch: pytest.MonkeyPatch, face_app_stub: FakeFaceAnalysis
) -> Iterator[TestClient]:
    monkeypatch.setenv("SERVICE_TOKEN", TEST_TOKEN)
    main.app.dependency_overrides[main.get_face_app] = lambda: face_app_stub
    try:
        with TestClient(main.app) as test_client:
            yield test_client
    finally:
        main.app.dependency_overrides.clear()


@pytest.fixture
def auth_headers() -> dict[str, str]:
    return {"X-Service-Token": TEST_TOKEN}


@pytest.fixture
def synthetic_image_bytes() -> bytes:
    """Imagem sintética sem rosto — nunca uma foto real."""
    image = np.zeros((64, 64, 3), dtype=np.uint8)
    ok, buffer = cv2.imencode(".png", image)
    assert ok
    return buffer.tobytes()
