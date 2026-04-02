#!/usr/bin/env python3
"""Minimal analyzer wrapper contract for MasterOfDrums pipeline.

This is intentionally dependency-light so the repo has a concrete integration shape
before the real beat/drum analyzer stack is wired in. It demonstrates:

- required CLI surface: --input / --output
- optional backend command passthrough for real analyzer integration
- backend command env fallback so the wrapper entry point can stay stable across backend swaps
- optional primary/fallback backend selection for validation-driven rollouts
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


DEFAULT_BACKEND_ENV = "PIPELINE_ANALYZER_BACKEND_COMMAND"
DEFAULT_PRIMARY_BACKEND_ENV = "PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND"
DEFAULT_FALLBACK_BACKEND_ENV = "PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND"
DEFAULT_FALLBACK_POLICY_ENV = "PIPELINE_ANALYZER_FALLBACK_POLICY"
DEFAULT_VALIDATION_MODE_ENV = "PIPELINE_ANALYZER_VALIDATION_MODE"

VALID_FALLBACK_POLICIES = {
    "disabled",
    "never",
    "on-error",
    "on-invalid",
    "on-error-or-invalid",
    "always",
}
VALID_VALIDATION_MODES = {
    "none",
    "require-timing",
}


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
        help="legacy single backend shell command; may use {input} and {output} placeholders",
    )
    parser.add_argument(
        "--backend-command-env",
        default=DEFAULT_BACKEND_ENV,
        help=f"environment variable to read the legacy backend command from when --backend-command is omitted (default: {DEFAULT_BACKEND_ENV})",
    )
    parser.add_argument(
        "--primary-backend-command",
        help="primary backend shell command for real analyzer integration; may use {input} and {output} placeholders",
    )
    parser.add_argument(
        "--primary-backend-command-env",
        default=DEFAULT_PRIMARY_BACKEND_ENV,
        help=f"environment variable to read the primary backend command from when --primary-backend-command is omitted (default: {DEFAULT_PRIMARY_BACKEND_ENV})",
    )
    parser.add_argument(
        "--fallback-backend-command",
        help="fallback backend shell command; may use {input} and {output} placeholders",
    )
    parser.add_argument(
        "--fallback-backend-command-env",
        default=DEFAULT_FALLBACK_BACKEND_ENV,
        help=f"environment variable to read the fallback backend command from when --fallback-backend-command is omitted (default: {DEFAULT_FALLBACK_BACKEND_ENV})",
    )
    parser.add_argument(
        "--fallback-policy",
        help="fallback policy: disabled|on-error|on-invalid|on-error-or-invalid|always",
    )
    parser.add_argument(
        "--fallback-policy-env",
        default=DEFAULT_FALLBACK_POLICY_ENV,
        help=f"environment variable to read the fallback policy from when --fallback-policy is omitted (default: {DEFAULT_FALLBACK_POLICY_ENV})",
    )
    parser.add_argument(
        "--validation-mode",
        help="validation mode for primary backend payloads: none|require-timing",
    )
    parser.add_argument(
        "--validation-mode-env",
        default=DEFAULT_VALIDATION_MODE_ENV,
        help=f"environment variable to read the validation mode from when --validation-mode is omitted (default: {DEFAULT_VALIDATION_MODE_ENV})",
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


def normalize_mode(raw: str | None, *, valid: set[str], default: str, alias_map: dict[str, str] | None = None) -> str:
    if raw is None:
        return default
    value = raw.strip().lower()
    if alias_map:
        value = alias_map.get(value, value)
    if value not in valid:
        raise RuntimeError(f"unsupported mode '{raw}'; expected one of: {', '.join(sorted(valid))}")
    return value


def env_or_arg(value: str | None, env_name: str | None) -> str | None:
    if value:
        return value
    if env_name:
        return os.environ.get(env_name)
    return None


def extract_timing_values(node: Any) -> list[float]:
    results: list[float] = []

    def visit(value: Any) -> None:
        if value is None:
            return
        if isinstance(value, (int, float)):
            parsed = safe_float(value)
            if parsed is not None:
                results.append(parsed)
            return
        if isinstance(value, dict):
            for key in ("seconds", "time", "start", "offset", "position"):
                if key in value:
                    visit(value[key])
                    return
            return
        if isinstance(value, list):
            for item in value:
                visit(item)

    visit(node)
    return results


TIMING_KEYS = (
    "beats",
    "beatTimes",
    "beat_times",
    "downbeats",
    "downbeatTimes",
    "downbeat_times",
    "subdivisions",
    "subdivisionTimes",
    "subdivision_times",
    "tatums",
    "tatumTimes",
    "tatum_times",
)


def payload_has_timing(payload: dict[str, Any]) -> bool:
    for key in TIMING_KEYS:
        values = extract_timing_values(payload.get(key))
        if values:
            return True

    timing = payload.get("timing")
    if isinstance(timing, dict):
        for key in TIMING_KEYS:
            values = extract_timing_values(timing.get(key))
            if values:
                return True

    raw = payload.get("rawAnalyzerOutput")
    if isinstance(raw, dict):
        return payload_has_timing(raw)

    for container_key in ("result", "output", "payload", "data", "response", "prediction"):
        nested = payload.get(container_key)
        if isinstance(nested, dict) and payload_has_timing(nested):
            return True

    return False


def validate_backend_payload(payload: dict[str, Any], validation_mode: str) -> list[str]:
    issues: list[str] = []
    if validation_mode == "none":
        return issues
    if validation_mode == "require-timing" and not payload_has_timing(payload):
        issues.append("payload did not contain recognizable beat/downbeat/subdivision timing")
    return issues


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


def annotate_backend_runtime(payload: dict[str, Any], *, selected_backend: str, selected_command: str, fallback_policy: str, validation_mode: str, fallback_used: bool, fallback_reason: str | None, primary_command: str | None, fallback_command: str | None) -> None:
    runtime = payload.setdefault("runtime", {})
    if isinstance(runtime, dict):
        runtime.setdefault("wrapper", "scripts/analyzer-wrapper.py")
        runtime.setdefault("backendCommand", selected_command)
        runtime.setdefault("selectedBackend", selected_backend)
        runtime.setdefault("fallbackPolicy", fallback_policy)
        runtime.setdefault("validationMode", validation_mode)
        runtime.setdefault("fallbackUsed", fallback_used)
        runtime.setdefault("fallbackReason", fallback_reason)
        runtime.setdefault("primaryBackendCommand", primary_command)
        runtime.setdefault("fallbackBackendCommand", fallback_command)
        runtime.setdefault("inputPath", input_path := os.environ.get("PIPELINE_ANALYZER_INPUT_PATH"))
        runtime.setdefault("outputPath", os.environ.get("PIPELINE_ANALYZER_OUTPUT_PATH"))
        runtime.setdefault("workflowID", os.environ.get("PIPELINE_ANALYZER_WORKFLOW_ID"))
        runtime.setdefault("jobID", os.environ.get("PIPELINE_ANALYZER_JOB_ID"))
        runtime.setdefault("requestedBy", os.environ.get("PIPELINE_ANALYZER_REQUESTED_BY"))
        runtime.setdefault("sourceType", os.environ.get("PIPELINE_ANALYZER_SOURCE_TYPE"))
        runtime.setdefault("sourceURI", os.environ.get("PIPELINE_ANALYZER_SOURCE_URI"))
        runtime.setdefault("schemaURI", os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_URI"))
        runtime.setdefault("schemaVersion", os.environ.get("PIPELINE_ANALYZER_CONTRACT_SCHEMA_VERSION"))
        if input_path is None:
            runtime.pop("inputPath", None)


def append_warning(payload: dict[str, Any], message: str) -> None:
    warnings = payload.setdefault("warnings", [])
    if isinstance(warnings, list):
        warnings.append(message)


def run_primary_fallback_backends(*, input_path: str, output_path: str, primary_command: str | None, fallback_command: str | None, fallback_policy: str, validation_mode: str, allow_stdout_json: bool) -> dict[str, Any]:
    if not primary_command and fallback_command:
        fallback_payload = run_backend_command(fallback_command, input_path=input_path, output_path=output_path, allow_stdout_json=allow_stdout_json)
        annotate_backend_runtime(
            fallback_payload,
            selected_backend="fallback",
            selected_command=fallback_command,
            fallback_policy=fallback_policy,
            validation_mode=validation_mode,
            fallback_used=True,
            fallback_reason="primary backend command not configured",
            primary_command=primary_command,
            fallback_command=fallback_command,
        )
        append_warning(fallback_payload, "analyzer wrapper used fallback backend because no primary backend command was configured")
        return fallback_payload

    if not primary_command:
        raise RuntimeError("no analyzer backend command was configured")

    if fallback_policy == "always" and fallback_command:
        fallback_payload = run_backend_command(fallback_command, input_path=input_path, output_path=output_path, allow_stdout_json=allow_stdout_json)
        annotate_backend_runtime(
            fallback_payload,
            selected_backend="fallback",
            selected_command=fallback_command,
            fallback_policy=fallback_policy,
            validation_mode=validation_mode,
            fallback_used=True,
            fallback_reason="fallback policy forced fallback backend",
            primary_command=primary_command,
            fallback_command=fallback_command,
        )
        append_warning(fallback_payload, "analyzer wrapper skipped primary backend because fallback policy was set to always")
        return fallback_payload

    try:
        payload = run_backend_command(primary_command, input_path=input_path, output_path=output_path, allow_stdout_json=allow_stdout_json)
    except RuntimeError as exc:
        if fallback_command and fallback_policy in {"on-error", "on-error-or-invalid"}:
            fallback_payload = run_backend_command(fallback_command, input_path=input_path, output_path=output_path, allow_stdout_json=allow_stdout_json)
            annotate_backend_runtime(
                fallback_payload,
                selected_backend="fallback",
                selected_command=fallback_command,
                fallback_policy=fallback_policy,
                validation_mode=validation_mode,
                fallback_used=True,
                fallback_reason=f"primary backend failed: {exc}",
                primary_command=primary_command,
                fallback_command=fallback_command,
            )
            append_warning(fallback_payload, f"analyzer wrapper fell back after primary backend failure: {exc}")
            return fallback_payload
        raise

    issues = validate_backend_payload(payload, validation_mode)
    if issues and fallback_command and fallback_policy in {"on-invalid", "on-error-or-invalid"}:
        fallback_payload = run_backend_command(fallback_command, input_path=input_path, output_path=output_path, allow_stdout_json=allow_stdout_json)
        annotate_backend_runtime(
            fallback_payload,
            selected_backend="fallback",
            selected_command=fallback_command,
            fallback_policy=fallback_policy,
            validation_mode=validation_mode,
            fallback_used=True,
            fallback_reason="; ".join(issues),
            primary_command=primary_command,
            fallback_command=fallback_command,
        )
        append_warning(fallback_payload, f"analyzer wrapper fell back after primary backend validation failed: {'; '.join(issues)}")
        return fallback_payload

    annotate_backend_runtime(
        payload,
        selected_backend="primary",
        selected_command=primary_command,
        fallback_policy=fallback_policy,
        validation_mode=validation_mode,
        fallback_used=False,
        fallback_reason="; ".join(issues) if issues else None,
        primary_command=primary_command,
        fallback_command=fallback_command,
    )
    append_warning(payload, "analyzer wrapper delegated to backend command")
    if issues:
        append_warning(payload, f"analyzer wrapper primary backend validation warning: {'; '.join(issues)}")
    return payload


def run_real_analyzer(
    input_path: str,
    output_path: str,
    probe_only: bool,
    backend_command: str | None,
    primary_backend_command: str | None,
    fallback_backend_command: str | None,
    fallback_policy: str,
    validation_mode: str,
    backend_stdout_json: bool,
) -> dict[str, Any]:
    selected_primary = primary_backend_command or backend_command
    selected_fallback = fallback_backend_command

    if selected_primary or selected_fallback:
        return run_primary_fallback_backends(
            input_path=input_path,
            output_path=output_path,
            primary_command=selected_primary,
            fallback_command=selected_fallback,
            fallback_policy=fallback_policy,
            validation_mode=validation_mode,
            allow_stdout_json=backend_stdout_json,
        )

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
            "fallbackPolicy": fallback_policy,
            "validationMode": validation_mode,
            "fallbackUsed": False,
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

    legacy_backend_command = env_or_arg(args.backend_command, args.backend_command_env)
    primary_backend_command = env_or_arg(args.primary_backend_command, args.primary_backend_command_env)
    fallback_backend_command = env_or_arg(args.fallback_backend_command, args.fallback_backend_command_env)

    fallback_policy = normalize_mode(
        env_or_arg(args.fallback_policy, args.fallback_policy_env),
        valid=VALID_FALLBACK_POLICIES,
        default="disabled",
        alias_map={"never": "disabled", "on-failure": "on-error", "on-validate-failure": "on-invalid"},
    )
    validation_mode = normalize_mode(
        env_or_arg(args.validation_mode, args.validation_mode_env),
        valid=VALID_VALIDATION_MODES,
        default="none",
    )

    payload = run_real_analyzer(
        args.input,
        args.output,
        probe_only=args.probe_only,
        backend_command=legacy_backend_command,
        primary_backend_command=primary_backend_command,
        fallback_backend_command=fallback_backend_command,
        fallback_policy=fallback_policy,
        validation_mode=validation_mode,
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
