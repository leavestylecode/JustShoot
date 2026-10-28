#!/usr/bin/env python3
"""Inspect bundled LUT data without running or changing the application.

Run with the research environment's numpy and matplotlib installed:
    python audit_luts.py
The chart describes raw LUT files, not the complete JustShoot render pipeline.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LUMA = np.array([0.2126, 0.7152, 0.0722])


def read_cube(path: Path) -> tuple[np.ndarray, list[str]]:
    raw = path.read_bytes()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("gb18030")
    dimension = None
    domain_min, domain_max = [0, 0, 0], [1, 1, 1]
    rows, headers = [], []
    for line in text.splitlines():
        content = line.split("#", 1)[0].strip()
        parts = content.split()
        if not parts:
            if line.strip():
                headers.append(line)
            continue
        directive = parts[0].upper()
        if directive == "LUT_3D_SIZE":
            if dimension is not None or rows or len(parts) != 2:
                raise ValueError(f"{path}: malformed dimension")
            dimension = int(parts[1])
        elif directive == "TITLE":
            headers.append(line)
        elif directive in ("DOMAIN_MIN", "DOMAIN_MAX"):
            vector = list(map(float, parts[1:]))
            if len(vector) != 3:
                raise ValueError(f"{path}: invalid domain")
            if directive == "DOMAIN_MIN":
                domain_min = vector
            else:
                domain_max = vector
        else:
            if dimension is None or len(parts) != 3:
                raise ValueError(f"{path}: unsupported directive or sample")
            rows.append(list(map(float, parts)))
    data = np.array(rows, dtype=np.float64)
    if dimension is None or not 2 <= dimension <= 128:
        raise ValueError(f"{path}: invalid dimension")
    if data.shape != (dimension**3, 3) or not np.isfinite(data).all():
        raise ValueError(f"{path}: invalid sample count or nonfinite data")
    if domain_min != [0, 0, 0] or domain_max != [1, 1, 1]:
        raise ValueError(f"{path}: unsupported domain")
    # .cube files use red as the fastest changing coordinate.
    return data.reshape(dimension, dimension, dimension, 3), headers


def sample(table: np.ndarray, rgb: np.ndarray) -> np.ndarray:
    position = np.clip(rgb, 0, 1) * (len(table) - 1)
    lower = np.floor(position).astype(int)
    upper = np.minimum(lower + 1, len(table) - 1)
    fraction = position - lower
    result = np.zeros_like(position, dtype=np.float64)
    for b in (0, 1):
        for g in (0, 1):
            for r in (0, 1):
                flags = np.array([r, g, b])
                index = np.where(flags, upper, lower)
                weight = np.prod(np.where(flags, fraction, 1 - fraction), axis=-1)
                result += table[index[..., 2], index[..., 1], index[..., 0]] * weight[..., None]
    return result


def inspect(path: Path) -> dict:
    table, headers = read_cube(path)
    n = len(table)
    gray_nodes = table[np.arange(n), np.arange(n), np.arange(n)]
    node_luma = gray_nodes @ LUMA
    reverse_indices = np.where(np.diff(node_luma) < -1e-5)[0]
    gray_inputs = np.array([0, 0.05, 0.10, 0.18, 0.50, 0.90, 1])
    rgb = sample(table, np.repeat(gray_inputs[:, None], 3, axis=1))
    return {
        "file": str(path.relative_to(ROOT)),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "dimension": n,
        "sample_count": n**3,
        "headers": headers,
        "minimum": float(table.min()),
        "maximum": float(table.max()),
        "maximum_distance_from_8bit_grid": float(np.max(np.abs(table - np.round(table * 255) / 255))),
        "gray_node_luma_reversals": [
            {"input_from": float(i / (n - 1)), "input_to": float((i + 1) / (n - 1)),
             "luma_change": float(node_luma[i + 1] - node_luma[i])}
            for i in reverse_indices
        ],
        "gray_samples": [{"input_srgb_code": float(x), "output_rgb": v.tolist(),
                          "weighted_srgb_code": float(v @ LUMA)}
                         for x, v in zip(gray_inputs, rgb)],
    }


def main() -> None:
    # The probe must preserve arbitrary RGB exactly through an identity cube.
    b, g, r = np.meshgrid(*([np.linspace(0, 1, 3)] * 3), indexing="ij")
    identity = np.stack([r, g, b], axis=-1)
    probes = np.random.default_rng(42).random((512, 3))
    np.testing.assert_allclose(sample(identity, probes), probes, atol=1e-14)

    paths = sorted((ROOT / "JustShoot/Resources").glob("*.cube"))
    candidates = sorted((HERE / "candidates").glob("*.cube"))
    report = {
        "scope": "Raw LUT files only. Weighted sRGB codes are not linear luminance. No claim of film accuracy.",
        "bundled": [inspect(p) for p in paths],
        "candidates": [inspect(p) for p in candidates],
    }
    (HERE / "audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    x = np.linspace(0, 1, 1025)
    gray = np.repeat(x[:, None], 3, axis=1)
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.8), layout="constrained")
    for path in paths:
        table, _ = read_cube(path)
        axes[0].plot(x, sample(table, gray) @ LUMA, label=path.stem, linewidth=1.4)
    axes[0].plot(x, x, ":", color="#555555", label="Identity")
    axes[0].set(title="Bundled files: gray response", xlabel="Input sRGB code", ylabel="Weighted output sRGB code")
    axes[0].legend(fontsize=6.6, loc="upper left")
    table, _ = read_cube(ROOT / "JustShoot/Resources/KodakPortra400.cube")
    out = sample(table, gray)
    for channel, color in enumerate(["#c94a50", "#339466", "#3c75c5"]):
        axes[1].plot(x, out[:, channel], color=color, label="RGB"[channel])
    axes[1].plot(x, x, ":", color="#555555", label="Identity")
    axes[1].set(title="Current Portra: neutral input, tinted output", xlabel="Input sRGB code", ylabel="Output channel sRGB code")
    axes[1].legend(fontsize=8)
    axes[2].plot(x, out @ LUMA, label="Current raw Portra 25", linewidth=2, color="#c94a50")
    for path in candidates:
        if "_65" in path.stem:
            continue
        candidate, _ = read_cube(path)
        axes[2].plot(x, sample(candidate, gray) @ LUMA,
                     label=path.stem.replace("Portra400_", "").replace("_sRGB_33", ""))
    axes[2].plot(x, x, ":", color="#555555", label="Identity")
    axes[2].set(title="Model candidates: different paper renderings", xlabel="Input sRGB code", ylabel="Weighted output sRGB code")
    axes[2].legend(fontsize=7)
    for ax in axes:
        ax.set(xlim=(0, 1), ylim=(0, 1))
        ax.grid(alpha=0.15)
    fig.suptitle("JustShoot LUT audit | raw tables, no AWB / app calibration / optics / grain", fontsize=12)
    fig.savefig(HERE / "lut-analysis.png", dpi=150)
    plt.close(fig)
    print(f"Audited {len(paths)} bundled and {len(candidates)} candidate LUTs; identity interpolation check passed.")


if __name__ == "__main__":
    main()
