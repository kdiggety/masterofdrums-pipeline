#!/usr/bin/env python3
"""Minimal analyzer wrapper contract for MasterOfDrums pipeline.

This is intentionally dependency-light so the repo has a concrete integration shape
before the real beat/drum analyzer stack is wired in. It demonstrates:

- required CLI surface: --input / --output
- optional stdout JSON mode for wrapper authors
- stable JSON fields the Swift worker can normalize today
- useful metadata/warnings for downstream debugging

Replace `run_real_analyzer` with the actual DSP/model invocation later.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import subprocess
import sys
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="MasterOfDrums analyzer wrapper")
    parser.add_argument("--input", required=True, help="input audio path")
    parser.add_argument("--output", required=True, help="output JSON path")
    parser.add_argument(
        "--stdout-json",
        action="store_true",
        help="print JSON to stdout instead of writing --output (for runtime stdout fallback testing)",
    )
    parser.add_argument(
        "--probe-only",
        action="store_true",
        help="use ffprobe metadata only; no real beat/drum detector yet",
    )
    return parser


def maybe_ffprobe(input_path: str) -> dict[str, Any]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_streams",
        "-show_format",
        "-print_format",
        "json",
        input_path,
    ]
    try:
        result = subprocess.run(command, check=True, capture_output=True, text=True)
    except (FileNotFoundError, subprocess.CalledProcessError) as exc:
        return {"warning": f"ffprobe unavailable or failed: {exc}"}
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        return {"warning": f"ffprobe returned invalid JSON: {exc}"}


def first_audio_stream(probe: dict[str, Any]) -> dict[str, Any] | None:
    for stream in probe.get("streams", []):
        if stream.get("codec_type") == "audio":
            return stream
    return None


def safe_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if math.isfinite(parsed):
        return parsed
    return None


def run_real_analyzer(input_path: str, probe_only: bool) -> dict[str, Any]:
    # Real analyzer integration point.
    # In the short term we keep this honest: metadata-only output, no fake beats/events.
    probe = maybe_ffprobe(input_path)
    stream = first_audio_stream(probe) if isinstance(probe, dict) else None
    duration = safe_float((probe.get("format") or {}).get("duration")) if isinstance(probe, dict) else None
    channels = stream.get("channels") if stream else None
    warnings: list[str] = []

    if probe_only:
        warnings.append("probe-only mode enabled; beat/downbeat/drum-event arrays were not generated")
    if isinstance(probe, dict) and probe.get("warning"):
        warnings.append(str(probe["warning"]))
    warnings.append("real analyzer backend not wired yet; wrapper currently emits metadata-only analysis")

    payload: dict[str, Any] = {
        "analysis": {
            "audioTrackCount": 1 if stream else 0,
            "durationSeconds": duration,
            "estimatedSegmentCount": 1 if duration else 0,
            "confidence": None,
        },
        "segments": [
            {
                "index": 0,
                "startSeconds": 0.0,
                "endSeconds": duration,
                "label": "full_track",
            }
        ] if duration else [],
        "warnings": warnings,
        "note": "Analyzer wrapper emitted metadata-only output; add beat/downbeat/drum-event extraction in the backend.",
        "runtime": {
            "inputPath": input_path,
            "outputPath": os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH"),
            "workflowID": os.environ.get("PIPELINE_ANALYZER_WORKFLOW_ID"),
            "jobID": os.environ.get("PIPELINE_ANALYZER_JOB_ID"),
            "requestedBy": os.environ.get("PIPELINE_ANALYZER_REQUESTED_BY"),
            "sourceURI": os.environ.get("PIPELINE_ANALYZER_SOURCE_URI"),
        },
        "probe": probe,
    }
    if channels is not None:
        payload["analysis"]["channelCount"] = channels
    return payload


def main() -> int:
    args = build_parser().parse_args()
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    payload = run_real_analyzer(args.input, probe_only=args.probe_only)
    text = json.dumps(payload, sort_keys=True)

    if args.stdout_json:
        print(text)
    else:
        output_path.write_text(text + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    sys.exit(main())
