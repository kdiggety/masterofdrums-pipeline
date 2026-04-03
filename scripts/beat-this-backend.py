#!/usr/bin/env python3
"""beat_this-backed analyzer backend for MasterOfDrums pipeline.

Primary path:
- use beat_this Python API when available
- fall back to the beat_this CLI when only the executable is installed
- optionally fall back to the repo's heuristic backend if beat_this is unavailable or fails

The output stays in the loose analyzer JSON shape the Swift runtime already normalizes.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
from typing import Any

DEFAULT_MODEL = "final0"
DEFAULT_FALLBACK_ENV = "PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND"
DEFAULT_HEURISTIC_BACKEND = "python3 ./scripts/backend-analyzer.py --input {input} --output {output}"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="beat_this backend analyzer")
    parser.add_argument("--input", required=False, help="input audio path")
    parser.add_argument("--output", required=False, help="output JSON path")
    parser.add_argument("--model", default=os.environ.get("PIPELINE_BEAT_THIS_MODEL", DEFAULT_MODEL))
    parser.add_argument("--device", default=os.environ.get("PIPELINE_BEAT_THIS_DEVICE", "auto"))
    parser.add_argument("--float16", action="store_true", default=(os.environ.get("PIPELINE_BEAT_THIS_FLOAT16", "false").lower() == "true"))
    parser.add_argument("--dbn", action="store_true", default=(os.environ.get("PIPELINE_BEAT_THIS_DBN", "false").lower() == "true"))
    parser.add_argument("--fallback-command", help="optional shell command to run if beat_this is unavailable or fails")
    parser.add_argument("--fallback-command-env", default=DEFAULT_FALLBACK_ENV)
    parser.add_argument("--disable-fallback", action="store_true")
    return parser


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


def shell_escape(value: str) -> str:
    return shlex.quote(value)


def render_command(command: str, input_path: str, output_path: str) -> str:
    return command.replace("{input}", shell_escape(input_path)).replace("{output}", shell_escape(output_path))


def load_json_object(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object in {path}")
    return value


def infer_tempo(beats: list[float]) -> float | None:
    if len(beats) < 2:
        return None
    intervals = [current - previous for previous, current in zip(beats, beats[1:]) if current > previous]
    if not intervals:
        return None
    median_interval = statistics.median(intervals)
    if median_interval <= 0:
        return None
    bpm = 60.0 / median_interval
    while bpm < 70:
        bpm *= 2
    while bpm > 220:
        bpm /= 2
    return round(bpm, 3)


def infer_confidence(beats: list[float], downbeats: list[float]) -> float | None:
    if len(beats) < 2:
        return 0.35 if beats else None
    intervals = [current - previous for previous, current in zip(beats, beats[1:]) if current > previous]
    if not intervals:
        return None
    spread = statistics.pstdev(intervals) if len(intervals) > 1 else 0.0
    mean = statistics.fmean(intervals)
    stability = max(0.0, 1.0 - (spread / max(mean, 1e-6)))
    downbeat_bonus = 0.08 if downbeats else -0.05
    return round(min(0.99, max(0.2, stability + downbeat_bonus)), 4)


def build_segments(downbeats: list[float], duration: float | None) -> list[dict[str, Any]]:
    if not downbeats:
        if duration and duration > 0:
            return [{"index": 0, "startSeconds": 0.0, "endSeconds": round(duration, 6), "label": "full_track"}]
        return []
    segments: list[dict[str, Any]] = []
    terminal = duration if duration and duration > 0 else None
    for index, start in enumerate(downbeats):
        end = downbeats[index + 1] if index + 1 < len(downbeats) else terminal
        if end is None or end <= start:
            continue
        segments.append({
            "index": index,
            "startSeconds": round(start, 6),
            "endSeconds": round(end, 6),
            "label": f"bar_{index + 1}",
        })
    return segments


def maybe_ffprobe_duration(input_path: str) -> float | None:
    command = ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", input_path]
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    return safe_float(result.stdout.strip())


def run_python_api(input_path: str, *, model: str, device: str, dbn: bool) -> tuple[list[float], list[float], list[str], str]:
    from beat_this.inference import File2Beats  # type: ignore

    resolved_device = "cpu" if device == "auto" else device
    tracker = File2Beats(checkpoint_path=model, device=resolved_device, dbn=dbn)
    beats, downbeats = tracker(input_path)
    return [round(float(value), 6) for value in beats], [round(float(value), 6) for value in downbeats], [], "python_api"


def parse_beats_tsv(path: pathlib.Path) -> tuple[list[float], list[float]]:
    beats: list[float] = []
    downbeats: list[float] = []
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        columns = line.split()
        time_value = safe_float(columns[0])
        if time_value is None:
            continue
        beats.append(round(time_value, 6))
        marker = columns[1].lower() if len(columns) > 1 else ""
        marker_value = safe_float(columns[1]) if len(columns) > 1 else None
        if marker in {"1", "1.0", "downbeat", "db", "d"} or marker_value == 1.0:
            downbeats.append(round(time_value, 6))
    return beats, downbeats


def run_cli(input_path: str, *, model: str, device: str, dbn: bool, float16: bool) -> tuple[list[float], list[float], list[str], str]:
    executable = shutil.which("beat_this")
    if not executable:
        raise RuntimeError("beat_this CLI not found in PATH")
    with tempfile.TemporaryDirectory(prefix="mod-beat-this-") as temp_dir:
        beats_path = pathlib.Path(temp_dir) / "output.beats"
        command = [executable, input_path, "-o", str(beats_path), "--model", model]
        if device != "auto":
            command.append(f"--gpu={device}")
        if dbn:
            command.append("--dbn")
        if float16:
            command.append("--float16")
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or f"status {result.returncode}"
            raise RuntimeError(f"beat_this CLI failed: {detail}")
        if not beats_path.exists():
            raise RuntimeError(f"beat_this CLI did not write output beats file: {beats_path}")
        beats, downbeats = parse_beats_tsv(beats_path)
        warnings: list[str] = []
        if result.stderr.strip():
            warnings.append(f"beat_this CLI stderr: {result.stderr.strip()}")
        return beats, downbeats, warnings, "cli"


def run_beat_this(input_path: str, *, model: str, device: str, dbn: bool, float16: bool) -> tuple[list[float], list[float], list[str], str]:
    try:
        return run_python_api(input_path, model=model, device=device, dbn=dbn)
    except Exception as exc:
        api_error = f"beat_this python API unavailable or failed: {exc}"
    beats, downbeats, warnings, mode = run_cli(input_path, model=model, device=device, dbn=dbn, float16=float16)
    warnings.insert(0, api_error)
    return beats, downbeats, warnings, mode


def invoke_fallback(command: str, input_path: str, output_path: str, reason: str) -> dict[str, Any]:
    rendered = render_command(command, input_path=input_path, output_path=output_path)
    result = subprocess.run(rendered, shell=True, check=False, capture_output=True, text=True, env=os.environ.copy())
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"status {result.returncode}"
        raise RuntimeError(f"fallback backend failed after beat_this error ({reason}): {detail}")
    payload = load_json_object(pathlib.Path(output_path))
    warnings = payload.setdefault("warnings", [])
    if isinstance(warnings, list):
        warnings.insert(0, f"beat_this unavailable/failed; used fallback backend: {reason}")
    runtime = payload.setdefault("runtime", {})
    if isinstance(runtime, dict):
        runtime.setdefault("primaryBackend", "scripts/beat-this-backend.py")
        runtime.setdefault("fallbackBackendCommand", command)
    note = payload.get("note")
    payload["note"] = ((str(note) + " ") if note else "") + "Primary analyzer attempted beat_this, then fell back to heuristic backend."
    return payload


def make_payload(input_path: str, beats: list[float], downbeats: list[float], warnings: list[str], mode: str, model: str) -> dict[str, Any]:
    duration = beats[-1] if beats else maybe_ffprobe_duration(input_path)
    tempo = infer_tempo(beats)
    confidence = infer_confidence(beats, downbeats)
    if not downbeats:
        warnings.append("beat_this did not emit downbeats; downstream bar segmentation may be approximate")
    if len(beats) < 2:
        warnings.append("beat_this emitted too few beats for stable tempo inference")
    return {
        "analysis": {
            "audioTrackCount": 1,
            "durationSeconds": round(duration, 6) if duration else None,
            "estimatedSegmentCount": max(1, len(downbeats) if downbeats else 1),
            "estimatedTempoBPM": tempo,
            "downbeatOffsetSeconds": round(downbeats[0], 6) if downbeats else 0.0,
            "confidence": confidence,
        },
        "beats": beats,
        "downbeats": downbeats,
        "segments": build_segments(downbeats, duration),
        "warnings": warnings,
        "note": "beat_this backend emitted beat/downbeat timing only. It does not emit lane-level drum events; chart generation may therefore pair this timing with heuristicDrumEvents output or a future transcription backend.",
        "runtime": {
            "backend": "scripts/beat-this-backend.py",
            "mode": mode,
            "model": model,
            "inputPath": input_path,
            "outputPath": os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH"),
            "workflowID": os.environ.get("PIPELINE_ANALYZER_WORKFLOW_ID"),
            "jobID": os.environ.get("PIPELINE_ANALYZER_JOB_ID"),
            "requestedBy": os.environ.get("PIPELINE_ANALYZER_REQUESTED_BY"),
            "sourceType": os.environ.get("PIPELINE_ANALYZER_SOURCE_TYPE"),
            "sourceURI": os.environ.get("PIPELINE_ANALYZER_SOURCE_URI"),
            "schemaURI": os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI"),
            "schemaVersion": os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_VERSION"),
        },
    }


def main() -> int:
    args = build_parser().parse_args()
    input_path = args.input or os.environ.get("PIPELINE_ANALYZER_INPUT_PATH")
    output_path = args.output or os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH")
    if not input_path:
        raise SystemExit("missing input path; pass --input or set PIPELINE_ANALYZER_INPUT_PATH")
    if not output_path:
        raise SystemExit("missing output path; pass --output or set PIPELINE_ANALYZER_OUTPUT_PATH")

    destination = pathlib.Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)

    fallback_command = args.fallback_command
    if not fallback_command and args.fallback_command_env:
        fallback_command = os.environ.get(args.fallback_command_env)
    if not fallback_command and not args.disable_fallback:
        fallback_command = DEFAULT_HEURISTIC_BACKEND

    try:
        beats, downbeats, warnings, mode = run_beat_this(
            input_path,
            model=args.model,
            device=args.device,
            dbn=args.dbn,
            float16=args.float16,
        )
        payload = make_payload(input_path, beats, downbeats, warnings, mode, args.model)
    except Exception as exc:
        if args.disable_fallback or not fallback_command:
            raise SystemExit(f"beat_this backend failed and fallback is disabled: {exc}") from exc
        payload = invoke_fallback(fallback_command, input_path, output_path, reason=str(exc))

    destination.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
