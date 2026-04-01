#!/usr/bin/env python3
"""Minimal analyzer wrapper contract for MasterOfDrums pipeline.

This is intentionally dependency-light so the repo has a concrete integration shape
before the real beat/drum analyzer stack is wired in. It demonstrates:

- required CLI surface: --input / --output
- optional backend command passthrough for real analyzer integration
- backend command env fallback so the wrapper entry point can stay stable across backend swaps
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
import shlex
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
    parser.add_argument(
        "--backend-command",
        help="optional shell command for a real backend; may use {input} and {output} placeholders",
    )
    parser.add_argument(
        "--backend-command-env",
        default="PIPELINE_ANALYZER_BACKEND_COMMAND",
        help="environment variable to read the backend command from when --backend-command is omitted (default: PIPELINE_ANALYZER_BACKEND_COMMAND)",
    )
    parser.add_argument(
        "--backend-stdout-json",
        action="store_true",
        help="accept JSON from backend stdout when it does not write --output",
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


def shell_escape(value: str) -> str:
    return shlex.quote(value)


def looks_like_json(text: str) -> bool:
    text = text.lstrip()
    return text.startswith("{") or text.startswith("[")


def load_json_text(text: str, *, context: str) -> dict[str, Any]:
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{context} returned invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise RuntimeError(f"{context} returned JSON that was not an object")
    return value


def render_backend_command(command: str, input_path: str, output_path: str) -> str:
    return command.replace("{input}", shell_escape(input_path)).replace("{output}", shell_escape(output_path))


def run_backend_command(command: str, input_path: str, output_path: str, allow_stdout_json: bool) -> dict[str, Any]:
    rendered = render_backend_command(command, input_path=input_path, output_path=output_path)
    result = subprocess.run(rendered, shell=True, check=False, capture_output=True, text=True, env=os.environ.copy())
    stdout_text = result.stdout.strip()
    stderr_text = result.stderr.strip()

    if result.returncode != 0:
        details = [f"backend exited with status {result.returncode}"]
        if stderr_text:
            details.append(f"stderr: {stderr_text}")
        if stdout_text and not looks_like_json(stdout_text):
            details.append(f"stdout: {stdout_text}")
        raise RuntimeError(" | ".join(details))

    output_file = pathlib.Path(output_path)
    if output_file.exists():
        return load_json_text(output_file.read_text(encoding="utf-8"), context="backend output file")
    if allow_stdout_json and stdout_text and looks_like_json(stdout_text):
        return load_json_text(stdout_text, context="backend stdout")

    details = [f"backend did not write output file: {output_path}"]
    if allow_stdout_json:
        details.append("stdout fallback was enabled but backend stdout did not contain JSON")
    if stderr_text:
        details.append(f"stderr: {stderr_text}")
    if stdout_text:
        details.append(f"stdout: {stdout_text}")
    raise RuntimeError(" | ".join(details))


def run_real_analyzer(input_path: str, output_path: str, probe_only: bool, backend_command: str | None, backend_stdout_json: bool) -> dict[str, Any]:
    if backend_command:
        payload = run_backend_command(
            backend_command,
            input_path=input_path,
            output_path=output_path,
            allow_stdout_json=backend_stdout_json,
        )
        runtime = payload.setdefault("runtime", {})
        if isinstance(runtime, dict):
            runtime.setdefault("wrapper", "scripts/analyzer-wrapper.py")
            runtime.setdefault("backendCommand", backend_command)
            runtime.setdefault("inputPath", input_path)
            runtime.setdefault("outputPath", os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH"))
            runtime.setdefault("workflowID", os.environ.get("PIPELINE_ANALYZER_WORKFLOW_ID"))
            runtime.setdefault("jobID", os.environ.get("PIPELINE_ANALYZER_JOB_ID"))
            runtime.setdefault("requestedBy", os.environ.get("PIPELINE_ANALYZER_REQUESTED_BY"))
            runtime.setdefault("sourceType", os.environ.get("PIPELINE_ANALYZER_SOURCE_TYPE"))
            runtime.setdefault("sourceURI", os.environ.get("PIPELINE_ANALYZER_SOURCE_URI"))
            runtime.setdefault("schemaURI", os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI"))
            runtime.setdefault("schemaVersion", os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_VERSION"))
        warnings = payload.setdefault("warnings", [])
        if isinstance(warnings, list):
            warnings.append("analyzer wrapper delegated to backend command")
        return payload

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
            "wrapper": "scripts/analyzer-wrapper.py",
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
        "probe": probe,
    }
    if channels is not None:
        payload["analysis"]["channelCount"] = channels
    return payload


def main() -> int:
    args = build_parser().parse_args()
    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    backend_command = args.backend_command
    if not backend_command and args.backend_command_env:
        backend_command = os.environ.get(args.backend_command_env)

    payload = run_real_analyzer(
        args.input,
        args.output,
        probe_only=args.probe_only,
        backend_command=backend_command,
        backend_stdout_json=args.backend_stdout_json,
    )
    text = json.dumps(payload, sort_keys=True)

    if args.stdout_json:
        print(text)
    else:
        output_path.write_text(text + "\n", encoding="utf-8")

    return 0


if __name__ == "__main__":
    sys.exit(main())
