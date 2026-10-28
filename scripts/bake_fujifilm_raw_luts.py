#!/usr/bin/env python3
"""Convert Fujifilm's official LUTs into self-contained linear-RAW-to-sRGB CLFs.

Input is developed, scene-linear Rec.2020/D65 RGB, not sensor mosaics or a
default rendered ProRAW image. All transfer curves are baked into half-domain
1D tables; the original 65-cube is retained without resampling. No Log node,
external transform, or F-Log image is required to apply the resulting CLF.

Research conversion only: this does not enable RAW capture or CLF loading in
the app. Install fujifilm-raw-lut-requirements.txt in a research environment.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import zipfile

import numpy as np
import PyOpenColorIO as ocio

from bake_film_luts import sample

ROOT = Path(__file__).resolve().parent.parent
RESEARCH = ROOT / "research/luts-2026-10-24"
ARCHIVE_SHA256 = "febfc7050999620651ca0cf162bf8b499970ef270b4da632765b61b958cf7940"
OFFICIAL_URL = "https://dl.fujifilm-x.com/support/lut/gfx-eterna-55-3d-lut-v110.zip"
MODES = ("PROVIA", "Velvia", "ASTIA", "CLASSIC-CHROME", "CLASSIC-Neg.", "ACROS")


def source_encoding(linear: np.ndarray) -> np.ndarray:
    """Official F-Log2 formula, used only to build the input lookup table."""
    values = np.asarray(linear, dtype=np.float64)
    output = 8.799461 * values + 0.092864
    mask = values >= 0.000889
    output[mask] = 0.245281 * np.log10(5.555556 * values[mask] + 0.064829) + 0.384316
    return np.clip(output, 0, 1)


def display_to_srgb(code: np.ndarray) -> np.ndarray:
    """Match the white paper's Gamma 2.2 viewing recommendation in sRGB.

    The official cube headers specify BT.709 primaries, not an EOTF. Gamma
    2.2 is an explicit viewing assumption, recorded in the manifest.
    """
    linear = np.clip(np.asarray(code, dtype=np.float64), 0, 1) ** 2.2
    output = 12.92 * linear
    mask = linear > 0.0031308
    output[mask] = 1.055 * linear[mask] ** (1 / 2.4) - 0.055
    return output


def official_table(data: bytes) -> np.ndarray:
    lines = data.decode("utf-8-sig").splitlines()
    assert "#Gamut:F-Gamut to ITU-R BT.709" in lines
    assert "LUT_3D_SIZE 65" in lines
    rows = [line for line in lines if line.strip() and not line.startswith(("#", "LUT_"))]
    table = np.fromstring("\n".join(rows), sep=" ", dtype=np.float32).reshape(65, 65, 65, 3)
    assert np.isfinite(table).all() and table.min() >= 0 and table.max() <= 1
    return table


def half_domain_table(function, name: str):
    # CLF half-domain indexes are IEEE-754 half bit patterns, including sign.
    half = np.arange(65536, dtype=np.uint16).view(np.float16).astype(np.float64)
    finite = np.nan_to_num(half, nan=0, posinf=65504, neginf=-65504)
    values = function(finite).astype(np.float32)
    assert np.isfinite(values).all()
    lut = ocio.Lut1DTransform(length=65536, inputHalfDomain=True)
    lut.setData(np.ascontiguousarray(np.repeat(values[:, None], 3, axis=1)))
    lut.setInterpolation(ocio.INTERP_LINEAR)
    lut.getFormatMetadata().setName(name)
    return lut


def make_probes() -> np.ndarray:
    rng = np.random.default_rng(20261024)
    rgb = rng.random((16384, 3)) * np.exp2(rng.uniform(-12, 8, (16384, 1)))
    negative = rng.uniform(-0.02, 1, (2048, 3))
    gray_values = np.concatenate(([-0.1, -0.01, 0], np.geomspace(1e-7, 64, 4097), [65504]))
    gray = np.repeat(gray_values[:, None], 3, axis=1)
    anchors = np.array([[0, 0, 0], [.18, .18, .18], [1, 1, 1], [4, 4, 4],
                        [16, 16, 16], [.5, .25, .75], [1, 0, 0], [0, 1, 0], [0, 0, 1]])
    return np.concatenate((anchors, rgb, negative, gray)).astype(np.float32)


def validate(path: Path, table: np.ndarray, probes: np.ndarray) -> dict:
    # Independently evaluate the official source and analytic curves in NumPy,
    # then read the serialized CLF with OpenColorIO and compare actual results.
    reference = display_to_srgb(sample(table, source_encoding(probes)))
    transformed = probes.copy()
    transform = ocio.FileTransform(src=str(path.resolve()), interpolation=ocio.INTERP_LINEAR)
    cpu = ocio.Config.CreateRaw().getProcessor(transform).getDefaultCPUProcessor()
    cpu.applyRGB(transformed)
    assert np.isfinite(transformed).all()
    difference = np.abs(transformed - reference)
    assert np.percentile(difference, 95) < 2e-5, difference.max()
    assert difference.max() < 2e-4, difference.max()
    # Regression: highlight inputs must reach the official curve, not be
    # truncated to 1 before lookup. Also catches an accidentally unit-domain LUT.
    highlight = np.repeat(np.array([.18, 1, 4, 16], dtype=np.float32)[:, None], 3, axis=1)
    rendered_highlight = highlight.copy()
    cpu.applyRGB(rendered_highlight)
    np.testing.assert_allclose(rendered_highlight,
                               display_to_srgb(sample(table, source_encoding(highlight))),
                               atol=2e-4)
    return {"probeCount": len(probes), "seed": 20261024,
            "reference": "Analytic source encoding + original 65-cube trilinear + Gamma 2.2 to sRGB",
            "implementation": "Serialized CLF evaluated independently by OpenColorIO",
            "absoluteRGBErrorP95": float(np.percentile(difference, 95)),
            "absoluteRGBErrorMax": float(difference.max()),
            "highlightInputs": highlight[:, 0].tolist(),
            "highlightOutputs": rendered_highlight.tolist(),
            "interpretation": "Numerical conversion fidelity only; not iPhone/Fujifilm camera color matching"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path,
                        default=RESEARCH / "official/fujifilm/gfx-eterna-55-3d-lut-v110.zip")
    parser.add_argument("--output", type=Path, default=RESEARCH / "derived/apple-raw-fujifilm")
    parser.add_argument("--modes", nargs="+", choices=MODES, default=["PROVIA"])
    args = parser.parse_args()
    assert hashlib.sha256(args.source.read_bytes()).hexdigest() == ARCHIVE_SHA256
    args.output.mkdir(parents=True, exist_ok=True)
    input_lut = half_domain_table(source_encoding, "Developed scene-linear input lookup")
    output_lut = half_domain_table(display_to_srgb, "sRGB output lookup (Gamma 2.2 reference view)")
    probes = make_probes()
    # Independent official black/18%-gray encoding anchors, in full-range codes.
    np.testing.assert_allclose(source_encoding(np.array([0, .18])), [95 / 1023, 400 / 1023], atol=1e-3)
    manifest = {
        "schemaVersion": 1,
        "status": "Official transform with versioned app RAW development contract",
        "source": {"url": OFFICIAL_URL, "archiveSHA256": ARCHIVE_SHA256,
                   "packageVersion": "1.10", "cubeVersion": "1.00"},
        "input": {"space": "Linear-transfer Rec.2020 / D65, developed from Apple RAW or ProRAW",
                  "normalization": "DNG exposure/local-gain adapted linear RGB (RAW recipe v3); LUT reference middle gray = 0.18; no per-image peak normalization",
                  "sensorDataAccepted": False,
                  "defaultRenderedProRAWAccepted": False,
                  "domain": "Finite half-float values; negatives and upper values follow official LUT domain clamping"},
        "rawDevelopmentContract": {"exposure": 0, "baselineExposure": "Preserve DNG default (per-image linear exposure compensation)",
                                   "shadowBias": 0, "boostAmount": 0, "localToneMapAmount": "Preserve DNG default for recipe version 3; zero for legacy version 1",
                                   "isGamutMappingEnabled": False,
                                   "whiteBalance": "Use captured DNG neutral; do not force 6500K",
                                   "workingFormat": "Floating point, preserve values above 1",
                                   "calibration": "DNG camera profile and exposure baseline retained; camera-to-camera color calibration not yet measured"},
        "output": "Encoded sRGB / D65, normalized RGB; write an sRGB profile in the final image",
        "outputViewingAssumption": "Official white paper p13 recommends BT.709 / D65 / Gamma 2.2. Decode that reference view with power 2.2 and encode sRGB; LUT header itself specifies BT.709 gamut only.",
        "runtime": "One self-contained CLF containing baked input LUT, original 65-cube, baked output LUT. No external F-Log stage or intermediate image. App consumes the exact tables as JSRAW001 with a dedicated RAW renderer.",
        "packages": {name: importlib.metadata.version(name) for name in ("numpy", "opencolorio")},
        "generatorSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "stocks": []}
    with zipfile.ZipFile(args.source) as archive:
        for mode in dict.fromkeys(args.modes):
            original = f"gfx-eterna-55-3d-lut-v110/65Grid/F-Log2/FLog2_to_{mode}_65grid_V.1.00.cube"
            data = archive.read(original)
            table = official_table(data)
            cube = ocio.Lut3DTransform(gridSize=65)
            # .cube is red-fast; OCIO arrays are blue-fast. Preserve all source nodes.
            cube.setData(np.ascontiguousarray(table.transpose(2, 1, 0, 3)))
            cube.setInterpolation(ocio.INTERP_LINEAR)
            cube.getFormatMetadata().setName(f"Original FUJIFILM {mode} 65-cube")
            group = ocio.GroupTransform([input_lut, cube, output_lut])
            metadata = group.getFormatMetadata()
            metadata.setName(f"FUJIFILM {mode} / developed Apple RAW linear Rec.2020 to sRGB")
            metadata.setID(f"JustShoot.Fujifilm.{mode}.RawLinearRec2020.sRGB.v1")
            metadata.addChildElement("InputDescriptor", "Developed scene-linear Rec.2020 / D65 RGB")
            metadata.addChildElement("OutputDescriptor", "Encoded sRGB / D65 RGB")
            metadata.addChildElement("Description", "Derived conversion, not a Fujifilm-authored Apple RAW LUT. Source look unchanged. See manifest.json for RAW development and reference-view assumptions.")
            path = args.output / f"Fuji{mode}_AppleRAW_LinearRec2020_to_sRGB.clf"
            group.write("Academy/ASC Common LUT Format", str(path))
            report = validate(path, table, probes)
            entry = {"mode": mode, "file": path.name, "bytes": path.stat().st_size,
                     "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                     "originalPath": original, "originalSHA256": hashlib.sha256(data).hexdigest(),
                     "sourceCubeResampled": False, "validation": report}
            manifest["stocks"].append(entry)
            print(f"{mode}: validated {report['probeCount']} probes; max RGB error {report['absoluteRGBErrorMax']:.8f}", flush=True)
    (args.output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
