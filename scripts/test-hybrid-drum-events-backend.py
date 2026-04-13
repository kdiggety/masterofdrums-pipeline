#!/usr/bin/env python3
"""Smoke tests for scripts/hybrid-drum-events-backend.py."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKEND = ROOT / "scripts" / "hybrid-drum-events-backend.py"

TIMING_BACKEND = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'analysis': {'audioTrackCount': 1, 'estimatedSegmentCount': 1, 'durationSeconds': 1.0, 'estimatedTempoBPM': 120.0, 'confidence': 0.95}, 'beats': [0.0, 0.5, 1.0], 'downbeats': [0.0], 'warnings': ['timing-ok'], 'runtime': {'backend': 'fixture-timing'}}) + '\n', encoding='utf-8')"
)

EVENT_BACKEND = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'drumEvents': [{'eventID': 'evt-1', 'onsetSeconds': 0.0, 'lane': 'kick', 'label': 'kick', 'confidence': 0.9}, {'eventID': 'evt-2', 'onsetSeconds': 0.5, 'lane': 'snare', 'label': 'snare', 'confidence': 0.88}], 'warnings': ['event-ok'], 'note': 'event candidates ready', 'runtime': {'backend': 'fixture-event'}}) + '\n', encoding='utf-8')"
)

EMPTY_EVENT_BACKEND = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'drumEvents': [], 'warnings': ['no-events'], 'runtime': {'backend': 'fixture-empty-event'}}) + '\n', encoding='utf-8')"
)


def backend_command(code: str) -> str:
    return f"{sys.executable} -c {code!r} --input {{input}} --output {{output}}"


def run_backend(tempdir: pathlib.Path, *extra_args: str) -> tuple[int, str, str, pathlib.Path]:
    input_path = tempdir / "input.wav"
    output_path = tempdir / "output.json"
    input_path.write_bytes(b"RIFF")
    command = [sys.executable, str(BACKEND), "--input", str(input_path), "--output", str(output_path), *extra_args]
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    return result.returncode, result.stdout, result.stderr, output_path


def test_optional_event_backend_merges_candidates() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        code, stdout, stderr, output_path = run_backend(
            tempdir,
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-backend-command",
            backend_command(EVENT_BACKEND),
            "--event-policy",
            "optional",
        )
        assert code == 0, (stdout, stderr)
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        runtime = payload.get("runtime", {})
        assert runtime.get("backend") == "scripts/hybrid-drum-events-backend.py", runtime
        assert runtime.get("eventBackendUsed") is True, runtime
        assert runtime.get("eventBackendCandidateCount") == 2, runtime
        assert len(payload.get("drumEvents", [])) == 2, payload
        assert any("Merged 2 stage-2 drum-event candidates" in warning for warning in payload.get("warnings", [])), payload
        assert any("event-backend: event-ok" == warning for warning in payload.get("warnings", [])), payload


def test_optional_event_backend_keeps_timing_only_when_no_candidates() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        code, stdout, stderr, output_path = run_backend(
            tempdir,
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-backend-command",
            backend_command(EMPTY_EVENT_BACKEND),
            "--event-policy",
            "optional",
        )
        assert code == 0, (stdout, stderr)
        payload = json.loads(output_path.read_text(encoding="utf-8"))
        runtime = payload.get("runtime", {})
        assert runtime.get("eventBackendUsed") is False, runtime
        assert runtime.get("eventBackendCandidateCount") == 0, runtime
        assert payload.get("drumEvents") is None, payload
        assert any("returned no drum-event candidates" in warning for warning in payload.get("warnings", [])), payload


def test_required_event_backend_fails_closed_when_missing() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        code, _, stderr, _ = run_backend(
            tempdir,
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-policy",
            "required",
        )
        assert code != 0, code
        assert "event policy is required" in stderr, stderr


if __name__ == "__main__":
    test_optional_event_backend_merges_candidates()
    test_optional_event_backend_keeps_timing_only_when_no_candidates()
    test_required_event_backend_fails_closed_when_missing()
    print("hybrid-drum-events-backend smoke tests passed")
