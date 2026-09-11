from fastapi.testclient import TestClient


def test_detect_without_token_is_rejected(client: TestClient) -> None:
    response = client.post("/detect", json={"image_url": "https://example.com/x.jpg"})
    assert response.status_code == 401
    assert response.json()["detail"]["error"]["code"] == "unauthorized"


def test_detect_with_wrong_token_is_rejected(client: TestClient) -> None:
    response = client.post(
        "/detect",
        json={"image_url": "https://example.com/x.jpg"},
        headers={"X-Service-Token": "wrong"},
    )
    assert response.status_code == 401


def test_embed_without_token_is_rejected(
    client: TestClient, synthetic_image_bytes: bytes
) -> None:
    response = client.post(
        "/embed", files={"file": ("selfie.png", synthetic_image_bytes, "image/png")}
    )
    assert response.status_code == 401


def test_metrics_without_token_is_rejected(client: TestClient) -> None:
    response = client.get("/metrics")
    assert response.status_code == 401


def test_metrics_with_token_is_allowed(
    client: TestClient, auth_headers: dict[str, str]
) -> None:
    response = client.get("/metrics", headers=auth_headers)
    assert response.status_code == 200
