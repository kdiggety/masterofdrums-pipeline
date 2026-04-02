#!/usr/bin/env python3
"""Fallback backend spike for madmom-style beat/downbeat output.

This script is intentionally modest:
- it can normalize precomputed madmom text outputs into the pipeline JSON seam
- it can derive a coarse tempo/downbeat offset estimate from those files
- it does not pretend to be a full production analyzer integration

Why this exists:
- the Swift worker already has a stable wrapper contract
- madmom packaging/runtime risk is real on modern machines
- we still want a concrete backend shape for fallback experiments now

Typical usage behind scripts/analyzer-wrapper.py:

  PIPELINE_AUDIO_ANALYZER_COMMAND="python3 ./scripts/analyzer-wrapper.py --input {input} --output {output}"
  PIPELINE_ANALYZER_BACKEND_COMMAND="python3 ./scripts/madmom-fallback-backend.py --input {input} --output {output} --beats-file ./tmp/song.beats.txt --downbeats-file ./tmp/song.downbeats.txt"

Expected text formats:
- beats file: one beat time in seconds per line, or 'time beat_number'
- downbeats file: one downbeat time in seconds per line, or the full madmom output with beat numbers where 1 marks a downbeat
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Normalize madmom fallback outputs into pipeline JSON")
    parser.add_argument("--input", required=True, help="input audio path")
    parser.add_argument("--output", required=True, help="output JSON path")
    parser.add_argument("--beats-file", help="path to madmom beat output text file")
    parser.add_argument("--downbeats-file", help="path to madmom downbeat output text file")
    parser.add_argument("--label", default="madmom_fallback_spike", help="note label for runtime metadata")
    return parser


def maybe_ffprobe(input_path: str) -> dict[str, Any]:
    command = [
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-print_format", "json", input_path,
    ]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        return json.loads(result.stdout)
    except Exception as exc:  # pragma: no cover - best-effort metadata only
        return {"warning": f"ffprobe unavailable or failed: {exc}"}


def safe_float(value: str) -> float | None:
    try:
        parsed = float(value)
    except Exception:
        return None
    return parsed if parsed >= 0 else None


def load_times(path: str | None, *, downbeats_only: bool = False) -> list[float]:
    if not path:
        return []
    values: list[float] = []
    for raw_line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if not parts:
            continue
        first = safe_float(parts[0])
        if first is None:
            continue
        if downbeats_only and len(parts) >= 2:
            beat_number = safe_float(parts[1])
            if beat_number is not None and int(round(beat_number)) != 1:
                continue
        values.append(first)
    return dedupe_sorted(values)


def dedupe_sorted(values: list[float]) -> list[float]:
    ordered = sorted(v for v in values if v >= 0)
    result: list[float] = []
    for value in ordered:
        if result and abs(result[-1] - value) <= 0.0005:
            continue
        result.append(value)
    return result


def estimate_tempo(beats: list[float]) -> float | None:
    if len(beats) < 2:
        return None
    intervals = [b - a for a, b in zip(beats, beats[1:]) if b > a]
    if not intervals:
        return None
    median_interval = statistics.median(intervals)
    if median_interval <= 0:
        return None
    return 60.0 / median_interval


def estimated_duration(probe: dict[str, Any]) -> float | None:
    try:
        return float((probe.get("format") or {}).get("duration"))
    except Exception:
        return None


def main() -> int:
    args = build_parser().parse_args()
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    beats = load_times(args.beats_file)
    downbeats = load_times(args.downbeats_file, downbeats_only=True)
    probe = maybe_ffprobe(args.input)
    duration = estimated_duration(probe)
    warnings: list[str] = []

    if not beats:
        warnings.append("madmom fallback spike did not receive beat times; downstream charting will use heuristic timing")
    if beats and not downbeats:
        warnings.append("madmom fallback spike has beats but no explicit downbeats; first beat will act as a provisional bar anchor")
    if isinstance(probe, dict) and probe.get("warning"):
        warnings.append(str(probe["warning"]))
    warnings.append("madmom fallback backend is a normalization spike, not a fully automated runtime integration")

    payload = {
        "analysis": {
            "audioTrackCount": 1,
            "durationSeconds": duration,
            "estimatedSegmentCount": max(len(downbeats), 1 if beats else 0),
            "estimatedTempoBPM": estimate_tempo(beats),
            "downbeatOffsetSeconds": downbeats[0] if downbeats else (beats[0] if beats else None),
            "confidence": 0.6 if beats else 0.2,
        },
        "timing": {
            "beats": beats,
            "downbeats": downbeats,
        },
        "segments": [
            {
                "index": index,
                "startSeconds": downbeat,
                "endSeconds": downbeats[index + 1] if index + 1 < len(downbeats) else duration,
                "label": f"bar_{index + 1}",
                "confidence": 0.6,
            }
            for index, downbeat in enumerate(downbeats)
        ],
        "warnings": warnings,
        "note": "madmom fallback spike normalized beat/downbeat text output into the pipeline contract seam",
        "runtime": {
            "backend": "scripts/madmom-fallback-backend.py",
            "label": args.label,
            "inputPath": args.input,
            "beatsFile": args.beats_file,
            "downbeatsFile": args.downbeats_file,
        },
        "probe": probe,
    }

    output_path.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
