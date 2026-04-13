#!/usr/bin/env python3
"""Hybrid analyzer backend: stable timing first, optional stage-2 drum-event candidates second.

This is the repo's low-risk seam for moving beyond timing-only beat_this output.
It keeps beat/downbeat timing owned by the primary timing backend (typically beat_this),
then optionally runs a second backend/adapter that emits lane-level drum-event candidates
(e.g. an ADTOF adapter, a future transcription model wrapper, or a fixture-backed spike).

The merged payload stays in the loose analyzer JSON shape the Swift runtime already normalizes.
That means the existing chart-generation path can start exercising analyzer-driven shaping
without forcing a heavyweight full-model integration into the default analyzer stack.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shlex
import subprocess
import tempfile
from typing import Any

DEFAULT_TIMING_ENV = "PIPELINE_ANALYZER_TIMING_BACKEND_COMMAND"
DEFAULT_EVENT_ENV = "PIPELINE_ANALYZER_EVENT_BACKEND_COMMAND"
DEFAULT_EVENT_POLICY_ENV = "PIPELINE_ANALYZER_EVENT_POLICY"
VALID_EVENT_POLICIES = {"disabled", "optional", "required"}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Hybrid timing + drum-event backend")
    parser.add_argument("--input", required=False, help="input audio path")
    parser.add_argument("--output", required=False, help="output JSON path")
    parser.add_argument("--timing-backend-command", help="shell command for the timing backend; may use {input} and {output}")
    parser.add_argument("--timing-backend-command-env", default=DEFAULT_TIMING_ENV)
    parser.add_argument("--event-backend-command", help="shell command for the event backend; may use {input} and {output}")
    parser.add_argument("--event-backend-command-env", default=DEFAULT_EVENT_ENV)
    parser.add_argument("--event-policy", choices=sorted(VALID_EVENT_POLICIES), help="disabled|optional|required")
    parser.add_argument("--event-policy-env", default=DEFAULT_EVENT_POLICY_ENV)
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


def normalize_policy(raw: str | None) -> str:
    value = (raw or "optional").strip().lower()
    if value not in VALID_EVENT_POLICIES:
        raise RuntimeError(f"unsupported event policy '{raw}'; expected one of: {', '.join(sorted(VALID_EVENT_POLICIES))}")
    return value


def load_json_object(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object in {path}")
    return value


def run_backend(command: str, *, input_path: str, output_path: str, cwd: pathlib.Path) -> dict[str, Any]:
    rendered = render_command(command, input_path=input_path, output_path=output_path)
    result = subprocess.run(rendered, shell=True, check=False, capture_output=True, text=True, cwd=str(cwd), env=os.environ.copy())
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"status {result.returncode}"
        raise RuntimeError(detail)
    payload = load_json_object(pathlib.Path(output_path))
    runtime = payload.setdefault("runtime", {})
    if isinstance(runtime, dict):
        runtime.setdefault("backendCommand", command)
    return payload


def extract_drum_events(payload: dict[str, Any]) -> list[Any]:
    for key in ("drumEvents", "drum_events", "events", "hits", "notes", "candidates", "predictions", "detections"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
    for key in ("result", "output", "payload", "data", "response", "prediction", "transcription", "drums", "percussion"):
        nested = payload.get(key)
        if isinstance(nested, dict):
            found = extract_drum_events(nested)
            if found:
                return found
    return []


def append_warning(payload: dict[str, Any], warning: str) -> None:
    warnings = payload.setdefault("warnings", [])
    if isinstance(warnings, list):
        warnings.append(warning)


def merge_payloads(timing_payload: dict[str, Any], event_payload: dict[str, Any] | None, *, event_policy: str, timing_command: str, event_command: str | None, event_failure: str | None) -> dict[str, Any]:
    merged = dict(timing_payload)

    runtime = merged.setdefault("runtime", {})
    if not isinstance(runtime, dict):
        runtime = {}
        merged["runtime"] = runtime
    timing_runtime = dict(runtime)
    runtime["backend"] = "scripts/hybrid-drum-events-backend.py"
    runtime["timingBackendRuntime"] = timing_runtime
    runtime["timingBackendCommand"] = timing_command
    runtime["eventBackendCommand"] = event_command
    runtime["eventPolicy"] = event_policy
    runtime["eventBackendRan"] = bool(event_payload)
    runtime["eventBackendUsed"] = False
    runtime["eventBackendCandidateCount"] = 0
    runtime["eventBackendFailure"] = event_failure

    note_parts = []
    if merged.get("note"):
        note_parts.append(str(merged["note"]))

    if event_payload:
        drum_events = extract_drum_events(event_payload)
        runtime["eventBackendCandidateCount"] = len(drum_events)
        if drum_events:
            merged["drumEvents"] = drum_events
            runtime["eventBackendUsed"] = True
            append_warning(merged, f"Merged {len(drum_events)} stage-2 drum-event candidates into timing-backed analyzer output")
            note_parts.append("Hybrid backend merged stage-2 drum-event candidates onto the timing backbone.")
        else:
            append_warning(merged, "Event backend returned no drum-event candidates; timing-only payload kept")
            note_parts.append("Hybrid backend kept timing-only output because the stage-2 event backend returned no candidates.")

        event_warnings = event_payload.get("warnings")
        if isinstance(event_warnings, list):
            for warning in event_warnings:
                if isinstance(warning, str):
                    append_warning(merged, f"event-backend: {warning}")

        event_note = event_payload.get("note")
        if event_note:
            runtime["eventBackendNote"] = str(event_note)

        event_runtime = event_payload.get("runtime")
        if isinstance(event_runtime, dict):
            runtime["eventBackendRuntime"] = event_runtime
    else:
        if event_policy == "disabled":
            append_warning(merged, "Stage-2 drum-event backend disabled; timing-only payload kept")
            note_parts.append("Hybrid backend ran timing only; stage-2 event backend disabled.")
        elif event_failure:
            append_warning(merged, f"Stage-2 drum-event backend failed; timing-only payload kept: {event_failure}")
            note_parts.append("Hybrid backend preserved timing output after stage-2 event backend failure.")
        else:
            append_warning(merged, "No stage-2 drum-event backend configured; timing-only payload kept")
            note_parts.append("Hybrid backend ran timing only; no stage-2 event backend configured.")

    merged["note"] = " ".join(part.strip() for part in note_parts if part).strip() or None
    return merged


def main() -> int:
    args = build_parser().parse_args()
    input_path = args.input or os.environ.get("PIPELINE_ANALYZER_INPUT_PATH")
    output_path = args.output or os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH")
    if not input_path:
        raise SystemExit("missing input path; pass --input or set PIPELINE_ANALYZER_INPUT_PATH")
    if not output_path:
        raise SystemExit("missing output path; pass --output or set PIPELINE_ANALYZER_OUTPUT_PATH")

    timing_command = env_or_arg(args.timing_backend_command, args.timing_backend_command_env)
    if not timing_command:
        raise SystemExit("missing timing backend command; pass --timing-backend-command or set PIPELINE_ANALYZER_TIMING_BACKEND_COMMAND")
    event_command = env_or_arg(args.event_backend_command, args.event_backend_command_env)
    event_policy = normalize_policy(env_or_arg(args.event_policy, args.event_policy_env))

    destination = pathlib.Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    cwd = pathlib.Path(__file__).resolve().parent.parent

    with tempfile.TemporaryDirectory(prefix="mod-hybrid-backend-") as temp_dir:
        temp_root = pathlib.Path(temp_dir)
        timing_output = temp_root / "timing.json"
        timing_payload = run_backend(timing_command, input_path=input_path, output_path=str(timing_output), cwd=cwd)

        event_payload: dict[str, Any] | None = None
        event_failure: str | None = None
        if event_policy != "disabled" and event_command:
            event_output = temp_root / "events.json"
            try:
                event_payload = run_backend(event_command, input_path=input_path, output_path=str(event_output), cwd=cwd)
            except Exception as exc:
                event_failure = str(exc)
                if event_policy == "required":
                    raise SystemExit(f"required event backend failed: {exc}") from exc
        elif event_policy == "required":
            raise SystemExit("event policy is required but no event backend command was configured")

        merged = merge_payloads(
            timing_payload,
            event_payload,
            event_policy=event_policy,
            timing_command=timing_command,
            event_command=event_command,
            event_failure=event_failure,
        )

    destination.write_text(json.dumps(merged, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
