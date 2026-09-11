"""Baixa os pesos do buffalo_l durante o build da imagem — nunca em runtime.

Usado só pelo Dockerfile. Não roda em CI nem em teste local: os testes
substituem o InsightFace real por um stub (ver tests/conftest.py).
"""

import os

from insightface.app import FaceAnalysis

root = os.environ.get("FACE_MODEL_ROOT", "/opt/insightface/models")
face_app = FaceAnalysis(name="buffalo_l", root=root)
face_app.prepare(ctx_id=-1, det_size=(640, 640))
