#!/usr/bin/env python3
"""Repo-local smoke tests for scripts/hybrid-drum-events-backend.py."""

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
    "pathlib.Path(a.output).write_text(json.dumps({'analysis': {'audioTrackCount': 1, 'estimatedSegmentCount': 1, 'durationSeconds': 1.5, 'estimatedTempoBPM': 120.0, 'confidence': 0.9}, 'beats': [0.0, 0.5, 1.0], 'downbeats': [0.0], 'warnings': ['timing-backend'], 'note': 'timing backbone ready'}) + '\n', encoding='utf-8')"
)

EVENT_BACKEND = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'drumEvents': [{'eventID': 'kick-1', 'onsetSeconds': 0.0, 'label': 'kick', 'velocity': 0.95}, {'eventID': 'snare-1', 'onsetSeconds': 0.5, 'label': 'snare', 'velocity': 0.85}], 'warnings': ['event-backend'], 'note': 'event candidates ready', 'runtime': {'backend': 'fixture-event'}}) + '\n', encoding='utf-8')"
)

EVENT_EMPTY = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "pathlib.Path(a.output).write_text(json.dumps({'warnings': ['event-backend-empty'], 'note': 'no event candidates', 'runtime': {'backend': 'fixture-empty-event'}}) + '\n', encoding='utf-8')"
)

EVENT_FAIL = "raise SystemExit(9)"


def backend_command(code: str) -> str:
    return f"{sys.executable} -c {code!r} --input {{input}} --output {{output}}"


def run_backend(tempdir: pathlib.Path, *extra_args: str) -> dict:
    input_path = tempdir / "input.wav"
    output_path = tempdir / "output.json"
    input_path.write_bytes(b"RIFF")
    command = [sys.executable, str(BACKEND), "--input", str(input_path), "--output", str(output_path), *extra_args]
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(f"hybrid backend failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return json.loads(output_path.read_text(encoding="utf-8"))


def test_merges_stage2_event_candidates_into_timing_payload() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_backend(
            tempdir,
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-backend-command",
            backend_command(EVENT_BACKEND),
            "--event-policy",
            "optional",
        )
        assert payload.get("beats") == [0.0, 0.5, 1.0], payload
        assert len(payload.get("drumEvents", [])) == 2, payload
        assert any("Merged 2 stage-2 drum-event candidates" in warning for warning in payload.get("warnings", [])), payload
        runtime = payload.get("runtime", {})
        assert runtime.get("eventBackendUsed") is True, runtime
        assert runtime.get("eventBackendRuntime", {}).get("backend") == "fixture-event", runtime


def test_timing_payload_marks_empty_event_backend_as_ran_but_unused() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_backend(
            tempdir,
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-backend-command",
            backend_command(EVENT_EMPTY),
            "--event-policy",
            "optional",
        )
        assert payload.get("beats") == [0.0, 0.5, 1.0], payload
        assert payload.get("drumEvents") is None, payload
        assert any("Event backend returned no drum-event candidates; timing-only payload kept" in warning for warning in payload.get("warnings", [])), payload
        runtime = payload.get("runtime", {})
        assert runtime.get("eventBackendRan") is True, runtime
        assert runtime.get("eventBackendUsed") is False, runtime
        assert runtime.get("eventBackendCandidateCount") == 0, runtime
        assert runtime.get("eventBackendRuntime", {}).get("backend") == "fixture-empty-event", runtime


def test_timing_payload_survives_optional_event_backend_failure() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_backend(
            tempdir,
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-backend-command",
            backend_command(EVENT_FAIL),
            "--event-policy",
            "optional",
        )
        assert payload.get("beats") == [0.0, 0.5, 1.0], payload
        assert payload.get("drumEvents") is None, payload
        assert any("Stage-2 drum-event backend failed; timing-only payload kept" in warning for warning in payload.get("warnings", [])), payload
        runtime = payload.get("runtime", {})
        assert runtime.get("eventBackendRan") is False, runtime
        assert runtime.get("eventBackendUsed") is False, runtime
        assert runtime.get("eventBackendCandidateCount") == 0, runtime
        assert "status 9" in (runtime.get("eventBackendFailure") or "") or runtime.get("eventBackendFailure"), runtime


def test_required_event_backend_failure_is_fatal() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        input_path = tempdir / "input.wav"
        output_path = tempdir / "output.json"
        input_path.write_bytes(b"RIFF")
        command = [
            sys.executable,
            str(BACKEND),
            "--input",
            str(input_path),
            "--output",
            str(output_path),
            "--timing-backend-command",
            backend_command(TIMING_BACKEND),
            "--event-backend-command",
            backend_command(EVENT_FAIL),
            "--event-policy",
            "required",
        ]
        result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
        assert result.returncode != 0, result
        assert "required event backend failed" in result.stderr or "required event backend failed" in result.stdout, result


if __name__ == "__main__":
    test_merges_stage2_event_candidates_into_timing_payload()
    test_timing_payload_marks_empty_event_backend_as_ran_but_unused()
    test_timing_payload_survives_optional_event_backend_failure()
    test_required_event_backend_failure_is_fatal()
    print("hybrid-drum-events-backend smoke tests passed")
