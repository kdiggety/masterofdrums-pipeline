#!/usr/bin/env python3
"""Repo-local smoke tests for scripts/analyzer-wrapper.py."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
WRAPPER = ROOT / "scripts" / "analyzer-wrapper.py"

PRIMARY_NO_TIMING = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'analysis': {'audioTrackCount': 1, 'estimatedSegmentCount': 1, 'durationSeconds': 1.0, 'confidence': 0.2}, 'warnings': ['primary-produced-no-timing']}) + '\\n', encoding='utf-8')"
)

FALLBACK_BEATS = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'analysis': {'audioTrackCount': 1, 'estimatedSegmentCount': 1, 'durationSeconds': 1.0, 'estimatedTempoBPM': 120.0, 'confidence': 0.8}, 'beats': [0.0, 0.5, 1.0], 'warnings': ['fallback-used']}) + '\\n', encoding='utf-8')"
)

PRIMARY_FAIL = "raise SystemExit(7)"

FALLBACK_DOWNBEATS = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'analysis': {'audioTrackCount': 1, 'estimatedSegmentCount': 1, 'durationSeconds': 1.0, 'estimatedTempoBPM': 98.0, 'confidence': 0.6}, 'downbeats': [0.0], 'warnings': ['fallback-after-error']}) + '\\n', encoding='utf-8')"
)

LEGACY_BACKEND = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'analysis': {'audioTrackCount': 1, 'estimatedSegmentCount': 1, 'durationSeconds': 1.0, 'estimatedTempoBPM': 111.0, 'confidence': 0.9}, 'beats': [0.0, 0.54], 'warnings': ['legacy-backend']}) + '\\n', encoding='utf-8')"
)


def backend_command(code: str) -> str:
    return f"{sys.executable} -c {code!r} --input {{input}} --output {{output}}"


def run_wrapper(tempdir: pathlib.Path, *extra_args: str) -> dict:
    input_path = tempdir / "input.wav"
    output_path = tempdir / "output.json"
    input_path.write_bytes(b"RIFF")
    command = [sys.executable, str(WRAPPER), "--input", str(input_path), "--output", str(output_path), *extra_args]
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(f"wrapper failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return json.loads(output_path.read_text(encoding="utf-8"))


def test_primary_validation_falls_back() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_wrapper(
            tempdir,
            "--primary-backend-command",
            backend_command(PRIMARY_NO_TIMING),
            "--fallback-backend-command",
            backend_command(FALLBACK_BEATS),
            "--fallback-policy",
            "on-error-or-invalid",
            "--validation-mode",
            "require-timing",
        )
        runtime = payload.get("runtime", {})
        assert runtime.get("selectedBackend") == "fallback", runtime
        assert runtime.get("fallbackUsed") is True, runtime
        assert "payload did not contain recognizable beat/downbeat/subdivision timing" in (runtime.get("fallbackReason") or "")
        assert "fallback-used" in payload.get("warnings", [])
        assert any("validation failed" in warning for warning in payload.get("warnings", [])), payload
        assert payload.get("beats") == [0.0, 0.5, 1.0], payload


def test_primary_failure_falls_back() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_wrapper(
            tempdir,
            "--primary-backend-command",
            backend_command(PRIMARY_FAIL),
            "--fallback-backend-command",
            backend_command(FALLBACK_DOWNBEATS),
            "--fallback-policy",
            "on-error",
        )
        runtime = payload.get("runtime", {})
        assert runtime.get("selectedBackend") == "fallback", runtime
        assert runtime.get("fallbackUsed") is True, runtime
        assert "primary backend failed" in (runtime.get("fallbackReason") or "")
        assert "fallback-after-error" in payload.get("warnings", [])
        assert any("fell back after primary backend failure" in warning for warning in payload.get("warnings", [])), payload


def test_legacy_backend_command_still_works() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_wrapper(
            tempdir,
            "--backend-command",
            backend_command(LEGACY_BACKEND),
        )
        runtime = payload.get("runtime", {})
        assert runtime.get("selectedBackend") == "primary", runtime
        assert runtime.get("fallbackUsed") is False, runtime
        assert "legacy-backend" in payload.get("warnings", [])
        assert "analyzer wrapper delegated to backend command" in payload.get("warnings", [])


if __name__ == "__main__":
    test_primary_validation_falls_back()
    test_primary_failure_falls_back()
    test_legacy_backend_command_still_works()
    print("analyzer-wrapper smoke tests passed")
