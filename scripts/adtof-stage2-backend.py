#!/usr/bin/env python3
"""Stage-2 ADTOF-style drum-event backend for MasterOfDrums pipeline.

This backend is meant to sit behind the hybrid/analyzer wrapper seam as the
lane-event producer while beat/downbeat timing stays owned by beat_this (or a
similar timing backend).

It supports two production-friendly modes:

1. Normalize an existing ADTOF-style JSON file via --input-json
2. Run an external transcription command via --backend-command / env, then
   normalize the resulting JSON file or stdout payload into loose drumEvents

The goal is to keep the pipeline contract stable while allowing the actual
transcription engine to evolve independently.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import subprocess
import sys
import tempfile
from typing import Any

DEFAULT_COMMAND_ENV = "PIPELINE_ADTOF_BACKEND_COMMAND"

MIDI_TO_LABEL = {
    35: "kick",
    36: "kick",
    37: "snare",
    38: "snare",
    39: "clap",
    40: "snare",
    41: "floor tom",
    42: "closed hi hat",
    43: "floor tom",
    44: "closed hi hat",
    45: "mid tom",
    46: "open hi hat",
    47: "high tom",
    48: "high tom",
    49: "crash",
    50: "high tom",
    51: "ride",
    52: "crash",
    53: "ride",
    55: "crash",
    57: "crash",
    59: "ride",
    60: "percussion",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Normalize ADTOF-style event output into pipeline-friendly loose JSON")
    parser.add_argument("--input", required=False, help="input audio path")
    parser.add_argument("--output", required=False, help="output JSON path")
    parser.add_argument("--input-json", help="existing raw ADTOF-style JSON file to normalize")
    parser.add_argument("--backend-command", help="external command that emits raw transcription JSON; may use {input} and {output}")
    parser.add_argument("--backend-command-env", default=DEFAULT_COMMAND_ENV)
    parser.add_argument("--backend-stdout-json", action="store_true", help="accept raw JSON from backend stdout when it does not write the temp output file")
    parser.add_argument("--confidence-default", type=float, default=0.5)
    parser.add_argument("--velocity-default", type=float, default=0.8)
    parser.add_argument("--label-prefix", default="adtof")
    return parser


def shell_escape(value: str) -> str:
    return shlex.quote(value)


def render_command(command: str, input_path: str, output_path: str) -> str:
    return command.replace("{input}", shell_escape(input_path)).replace("{output}", shell_escape(output_path))


def env_or_arg(value: str | None, env_name: str | None) -> str | None:
    if value:
        return value
    if env_name:
        return os.environ.get(env_name)
    return None


def maybe_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except Exception:
        return None
    if parsed != parsed or parsed in {float("inf"), float("-inf")}:
        return None
    return parsed


def normalize_velocity(value: Any, default: float) -> float | None:
    numeric = maybe_float(value)
    if numeric is None:
        return default
    if numeric > 1.0:
        numeric /= 127.0
    return min(max(numeric, 0.0), 1.0)


def first_value(item: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in item:
            return item[key]
    return None


def first_list(payload: dict[str, Any], *keys: str) -> list[Any]:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, list):
            return value
    return []


def nested_dict(payload: dict[str, Any], *keys: str) -> dict[str, Any] | None:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, dict):
            return value
    return None


def flatten_event_collections(payload: dict[str, Any]) -> list[dict[str, Any]]:
    direct = first_list(payload, "hits", "events", "notes", "detections", "predictions", "candidates")
    if direct:
        return [item for item in direct if isinstance(item, dict)]

    for container_key in ("result", "output", "payload", "data", "response", "prediction", "transcription", "drums", "percussion"):
        nested = nested_dict(payload, container_key)
        if nested:
            found = flatten_event_collections(nested)
            if found:
                return found

    instruments = first_list(payload, "instruments", "tracks", "sources")
    if instruments:
        flattened: list[dict[str, Any]] = []
        for instrument in instruments:
            if not isinstance(instrument, dict):
                continue
            label = first_value(instrument, "label", "name", "instrument", "class")
            midi = first_value(instrument, "midi", "pitch", "note")
            nested_hits = first_list(instrument, "hits", "events", "notes", "detections")
            for hit in nested_hits:
                if isinstance(hit, dict):
                    merged = dict(hit)
                    if label is not None and "label" not in merged and "instrument" not in merged:
                        merged["instrument"] = label
                    if midi is not None and "midi" not in merged and "pitch" not in merged:
                        merged["midi"] = midi
                    flattened.append(merged)
        if flattened:
            return flattened

    return []


def normalize_label(midi_or_label: Any) -> str | None:
    if isinstance(midi_or_label, (int, float)):
        return MIDI_TO_LABEL.get(int(midi_or_label), str(int(midi_or_label)))
    if midi_or_label is None:
        return None
    return str(midi_or_label)


def normalize_event(index: int, item: dict[str, Any], confidence_default: float, velocity_default: float, label_prefix: str) -> dict[str, Any] | None:
    onset = maybe_float(first_value(item, "onsetSeconds", "onset", "time", "start", "start_seconds", "time_seconds", "timestamp"))
    if onset is None:
        position = first_value(item, "position", "offset")
        if isinstance(position, dict):
            onset = maybe_float(first_value(position, "seconds", "timeSeconds", "time_seconds", "value"))
    if onset is None:
        return None

    midi = first_value(item, "pitch", "midi", "class", "note", "instrument_id")
    raw_label = first_value(item, "label", "name", "instrument", "class_name", "drum")
    label = normalize_label(midi) or normalize_label(raw_label) or "unknown"
    velocity = normalize_velocity(first_value(item, "velocity", "amplitude", "strength", "value"), velocity_default)
    confidence = maybe_float(first_value(item, "confidence", "probability", "score"))
    if confidence is None:
        confidence = confidence_default

    source_label = None
    if midi is not None:
        source_label = f"{label_prefix}_midi_{int(midi)}" if isinstance(midi, (int, float)) else f"{label_prefix}_{midi}"
    elif raw_label is not None:
        source_label = f"{label_prefix}_{str(raw_label).strip().lower().replace(' ', '_')}"
    else:
        source_label = f"{label_prefix}_unknown"

    return {
        "eventID": first_value(item, "eventID", "event_id", "id") or f"{label_prefix}-{index}",
        "onsetSeconds": onset,
        "label": label,
        "velocity": velocity,
        "confidence": confidence,
        "sourceLabel": source_label,
    }


def normalize_payload(payload: dict[str, Any], *, confidence_default: float, velocity_default: float, label_prefix: str, backend_command: str | None, input_json_path: str | None) -> dict[str, Any]:
    raw_events = flatten_event_collections(payload)
    drum_events = []
    dropped_missing_onset = 0
    for index, item in enumerate(raw_events):
        normalized = normalize_event(index, item, confidence_default, velocity_default, label_prefix)
        if normalized is None:
            dropped_missing_onset += 1
            continue
        drum_events.append(normalized)

    warnings = [
        "ADTOF stage-2 backend emitted drum-event candidates only; pair with a primary beat/downbeat analyzer for chart timing"
    ]
    if dropped_missing_onset:
        warnings.append(f"ADTOF stage-2 backend dropped {dropped_missing_onset} raw events without recognizable onset timing")
    if not drum_events:
        warnings.append("ADTOF stage-2 backend found no usable drum-event candidates in the raw payload")

    return {
        "analysis": {
            "audioTrackCount": 1,
            "estimatedSegmentCount": 1,
            "confidence": confidence_default if drum_events else 0.0,
        },
        "drumEvents": drum_events,
        "warnings": warnings,
        "note": "ADTOF stage-2 backend converted raw transcription output into the pipeline's loose drum-event shape",
        "runtime": {
            "backend": "scripts/adtof-stage2-backend.py",
            "backendCommand": backend_command,
            "inputJSON": input_json_path,
            "candidateCount": len(drum_events),
            "rawEventCount": len(raw_events),
            "labelPrefix": label_prefix,
        },
    }


def load_json_file(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object in {path}")
    return value


def run_backend(command: str, *, input_path: str, cwd: pathlib.Path, allow_stdout_json: bool) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="mod-adtof-stage2-") as temp_dir:
        temp_output = pathlib.Path(temp_dir) / "raw-output.json"
        rendered = render_command(command, input_path=input_path, output_path=str(temp_output))
        result = subprocess.run(rendered, shell=True, check=False, capture_output=True, text=True, cwd=str(cwd), env=os.environ.copy())
        stdout_text = result.stdout.strip()
        stderr_text = result.stderr.strip()
        if result.returncode != 0:
            detail = stderr_text or stdout_text or f"status {result.returncode}"
            raise RuntimeError(f"external ADTOF backend failed: {detail}")
        if temp_output.exists():
            return load_json_file(temp_output)
        if allow_stdout_json and stdout_text:
            value = json.loads(stdout_text)
            if not isinstance(value, dict):
                raise RuntimeError("external ADTOF backend stdout JSON was not an object")
            return value
        detail = stderr_text or stdout_text or "backend produced no output file"
        raise RuntimeError(f"external ADTOF backend produced no JSON payload: {detail}")


def main() -> int:
    args = build_parser().parse_args()
    input_path = args.input or os.environ.get("PIPELINE_ANALYZER_INPUT_PATH")
    output_path = args.output or os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH")
    if not output_path:
        raise SystemExit("missing output path; pass --output or set PIPELINE_ANALYZER_OUTPUT_PATH")

    backend_command = env_or_arg(args.backend_command, args.backend_command_env)
    if not args.input_json and not backend_command:
        raise SystemExit("provide either --input-json or --backend-command / PIPELINE_ADTOF_BACKEND_COMMAND")
    if backend_command and not input_path:
        raise SystemExit("backend command mode requires --input or PIPELINE_ANALYZER_INPUT_PATH")

    if args.input_json:
        raw_payload = load_json_file(pathlib.Path(args.input_json))
    else:
        raw_payload = run_backend(
            backend_command,
            input_path=input_path or "",
            cwd=pathlib.Path(__file__).resolve().parent.parent,
            allow_stdout_json=args.backend_stdout_json,
        )

    normalized = normalize_payload(
        raw_payload,
        confidence_default=args.confidence_default,
        velocity_default=args.velocity_default,
        label_prefix=args.label_prefix,
        backend_command=backend_command,
        input_json_path=args.input_json,
    )

    destination = pathlib.Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(normalized, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
