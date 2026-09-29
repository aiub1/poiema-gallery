from __future__ import annotations

import numpy as np

import main


def test_downscale_reduces_large_image_keeping_aspect_ratio() -> None:
    image = np.zeros((1200, 2400, 3), dtype=np.uint8)

    resized, scale = main.downscale(image, max_side=1600)

    assert scale == 800 / 1200
    height, width = resized.shape[:2]
    assert width == 1600
    assert height == 800


def test_downscale_never_upscales_smaller_image() -> None:
    image = np.zeros((300, 400, 3), dtype=np.uint8)

    resized, scale = main.downscale(image, max_side=1600)

    assert scale == 1.0
    assert resized.shape == image.shape
