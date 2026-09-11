from __future__ import annotations

import logging
import tempfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tests.conftest import FakeFace, FakeFaceAnalysis, make_embedding


def test_embed_no_face_returns_422(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    synthetic_image_bytes: bytes,
) -> None:
    face_app_stub.faces = []
    response = client.post(
        "/embed",
        headers=auth_headers,
        files={"file": ("selfie.png", synthetic_image_bytes, "image/png")},
    )
    assert response.status_code == 422
    assert response.json()["detail"]["error"]["code"] == "no_face_detected"


def test_embed_returns_embedding_of_best_face(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    synthetic_image_bytes: bytes,
) -> None:
    face_app_stub.faces = [
        FakeFace(normed_embedding=make_embedding(0.1), det_score=0.4),
        FakeFace(normed_embedding=make_embedding(0.9), det_score=0.95),
    ]
    response = client.post(
        "/embed",
        headers=auth_headers,
        files={"file": ("selfie.png", synthetic_image_bytes, "image/png")},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["quality"] == pytest.approx(0.95)
    assert len(body["embedding"]) == 512


def test_embed_never_writes_to_disk(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    synthetic_image_bytes: bytes,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    face_app_stub.faces = [FakeFace(normed_embedding=make_embedding(), det_score=0.9)]

    disk_writers = []
    for name in ("NamedTemporaryFile", "mkstemp", "TemporaryFile", "mkdtemp"):
        original = getattr(tempfile, name)

        def _forbidden(*args: object, _name: str = name, **kwargs: object) -> object:
            raise AssertionError(f"tempfile.{_name} não deveria ser chamado por /embed")

        monkeypatch.setattr(tempfile, name, _forbidden)
        disk_writers.append((name, original))

    tmp_dir = Path(tempfile.gettempdir())
    cwd = Path.cwd()
    before_tmp = set(tmp_dir.iterdir())
    before_cwd = set(cwd.iterdir())

    response = client.post(
        "/embed",
        headers=auth_headers,
        files={"file": ("selfie.png", synthetic_image_bytes, "image/png")},
    )
    assert response.status_code == 200

    after_tmp = set(tmp_dir.iterdir())
    after_cwd = set(cwd.iterdir())
    assert after_tmp == before_tmp, "arquivo novo apareceu no diretório temporário"
    assert after_cwd == before_cwd, "arquivo novo apareceu no diretório de trabalho"


def test_embed_does_not_log_embedding_or_filename(
    client: TestClient,
    face_app_stub: FakeFaceAnalysis,
    auth_headers: dict[str, str],
    synthetic_image_bytes: bytes,
    caplog: pytest.LogCaptureFixture,
) -> None:
    embedding = make_embedding(0.42)
    face_app_stub.faces = [FakeFace(normed_embedding=embedding, det_score=0.9)]

    with caplog.at_level(logging.DEBUG):
        response = client.post(
            "/embed",
            headers=auth_headers,
            files={"file": ("minha-selfie-secreta.png", synthetic_image_bytes, "image/png")},
        )
    assert response.status_code == 200

    log_text = "\n".join(record.getMessage() for record in caplog.records)
    assert "minha-selfie-secreta" not in log_text
    assert str(float(embedding[0])) not in log_text
    assert auth_headers["X-Service-Token"] not in log_text
