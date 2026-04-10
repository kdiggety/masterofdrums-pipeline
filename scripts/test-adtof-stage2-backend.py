#!/usr/bin/env python3
"""Repo-local smoke tests for scripts/adtof-stage2-backend.py."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
BACKEND = ROOT / "scripts" / "adtof-stage2-backend.py"
FIXTURE = ROOT / "scripts" / "fixtures" / "adtof-sample-events.json"

RAW_NESTED = {
    "transcription": {
        "tracks": [
            {
                "name": "kick",
                "midi": 36,
                "hits": [
                    {"time": 0.0, "velocity": 120, "confidence": 0.91},
                    {"time": 0.25, "velocity": 100, "confidence": 0.83},
                ],
            },
            {
                "name": "snare",
                "midi": 38,
                "hits": [
                    {"time": 0.5, "velocity": 118, "confidence": 0.88}
                ],
            },
        ]
    }
}

STDOUT_PAYLOAD = {
    "events": [
        {"onset": 0.0, "midi": 42, "velocity": 0.7, "confidence": 0.8},
        {"onset": 0.125, "midi": 42, "velocity": 0.65, "confidence": 0.79},
        {"onset": 0.5, "midi": 38, "velocity": 0.9, "confidence": 0.92},
    ]
}


def backend_command(payload: dict) -> str:
    code = (
        "import argparse, json, pathlib; "
        "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
        "a=p.parse_args(); "
        f"pathlib.Path(a.output).write_text(json.dumps({payload!r}) + '\\n', encoding='utf-8')"
    )
    return f"{sys.executable} -c {code!r} --input {{input}} --output {{output}}"


def stdout_backend_command(payload: dict) -> str:
    code = (
        "import argparse, json; "
        "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
        "p.parse_args(); "
        f"print(json.dumps({payload!r}))"
    )
    return f"{sys.executable} -c {code!r} --input {{input}} --output {{output}}"


def run_backend(tempdir: pathlib.Path, *extra_args: str) -> dict:
    input_path = tempdir / "input.wav"
    output_path = tempdir / "output.json"
    input_path.write_bytes(b"RIFF")
    command = [sys.executable, str(BACKEND), "--input", str(input_path), "--output", str(output_path), *extra_args]
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
        raise SystemExit(f"adtof stage2 backend failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
    return json.loads(output_path.read_text(encoding="utf-8"))


def test_normalizes_fixture_json() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_backend(tempdir, "--input-json", str(FIXTURE))
        assert len(payload.get("drumEvents", [])) >= 1, payload
        assert payload.get("runtime", {}).get("candidateCount") == len(payload.get("drumEvents", [])), payload
        assert any("ADTOF stage-2 backend emitted drum-event candidates only" in warning for warning in payload.get("warnings", [])), payload


def test_runs_external_backend_and_normalizes_nested_tracks() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_backend(
            tempdir,
            "--backend-command",
            backend_command(RAW_NESTED),
        )
        drum_events = payload.get("drumEvents", [])
        assert len(drum_events) == 3, payload
        assert [event["label"] for event in drum_events] == ["kick", "kick", "snare"], payload
        assert payload.get("runtime", {}).get("rawEventCount") == 3, payload


def test_accepts_backend_stdout_json_mode() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = run_backend(
            tempdir,
            "--backend-command",
            stdout_backend_command(STDOUT_PAYLOAD),
            "--backend-stdout-json",
        )
        drum_events = payload.get("drumEvents", [])
        assert len(drum_events) == 3, payload
        assert drum_events[0]["label"] == "closed hi hat", payload
        assert payload.get("runtime", {}).get("candidateCount") == 3, payload


if __name__ == "__main__":
    test_normalizes_fixture_json()
    test_runs_external_backend_and_normalizes_nested_tracks()
    test_accepts_backend_stdout_json_mode()
    print("adtof-stage2-backend smoke tests passed")
