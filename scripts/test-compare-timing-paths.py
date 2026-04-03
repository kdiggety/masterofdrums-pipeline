#!/usr/bin/env python3
"""Smoke tests for scripts/compare-timing-paths.py."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
COMPARE = ROOT / "scripts" / "compare-timing-paths.py"

PRIMARY = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "payload={"
    "'analysis': {'audioTrackCount': 1, 'durationSeconds': 2.0, 'estimatedSegmentCount': 2, 'estimatedTempoBPM': 120.0, 'downbeatOffsetSeconds': 0.0, 'confidence': 0.9}, "
    "'beats': [0.0, 0.5, 1.0, 1.5], "
    "'downbeats': [0.0], "
    "'segments': [{'index': 0, 'startSeconds': 0.0, 'endSeconds': 2.0, 'label': 'bar_1'}], "
    "'runtime': {'backend': 'primary-backend.py'}, "
    "'warnings': ['primary-path']}; "
    "pathlib.Path(a.output).write_text(json.dumps(payload) + '\\n', encoding='utf-8')"
)

FALLBACK = (
    "import argparse, json, pathlib; "
    "p=argparse.ArgumentParser(); p.add_argument('--input', required=True); p.add_argument('--output', required=True); "
    "a=p.parse_args(); "
    "payload={"
    "'analysis': {'audioTrackCount': 1, 'durationSeconds': 2.0, 'estimatedSegmentCount': 2, 'estimatedTempoBPM': 100.0, 'downbeatOffsetSeconds': 0.1, 'confidence': 0.7}, "
    "'beats': [0.1, 0.7, 1.3, 1.9], "
    "'downbeats': [0.1], "
    "'segments': [{'index': 0, 'startSeconds': 0.1, 'endSeconds': 2.0, 'label': 'bar_1'}], "
    "'runtime': {'backend': 'fallback-backend.py'}, "
    "'warnings': ['fallback-path']}; "
    "pathlib.Path(a.output).write_text(json.dumps(payload) + '\\n', encoding='utf-8')"
)


def backend_command(code: str) -> str:
    return f"{sys.executable} -c {code!r} --input {{input}} --output {{output}}"


def test_compare_generates_summary_files() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        input_path = tempdir / "input.wav"
        output_dir = tempdir / "compare"
        input_path.write_bytes(b"RIFF")

        result = subprocess.run(
            [
                sys.executable,
                str(COMPARE),
                "--input",
                str(input_path),
                "--output-dir",
                str(output_dir),
                "--primary-backend-command",
                backend_command(PRIMARY),
                "--fallback-backend-command",
                backend_command(FALLBACK),
            ],
            capture_output=True,
            text=True,
            cwd=ROOT,
        )
        if result.returncode != 0:
            raise SystemExit(f"compare script failed\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")

        summary_path = output_dir / "comparison-summary.json"
        text_path = output_dir / "comparison-summary.txt"
        assert summary_path.exists(), output_dir
        assert text_path.exists(), output_dir

        summary = json.loads(summary_path.read_text(encoding="utf-8"))
        assert summary["primary"]["tempoBPM"] == 120.0, summary
        assert summary["fallback"]["tempoBPM"] == 100.0, summary
        assert summary["delta"]["tempoBPM"]["delta"] == -20.0, summary
        assert summary["delta"]["downbeatOffsetSeconds"]["delta"] == 0.1, summary
        assert summary["delta"]["beatGrid"]["beatStarts"]["mismatchCount"] == 4, summary
        assert summary["delta"]["segments"]["boundaries"]["mismatchCount"] == 1, summary
        assert summary["delta"]["provenance"]["selectedBackend"] == {"primary": "primary", "fallback": "fallback"}, summary
        assert summary["delta"]["provenance"]["fallbackUsed"] == {"primary": False, "fallback": True}, summary

        text = text_path.read_text(encoding="utf-8")
        assert "timing path comparison" in text, text
        assert "tempo_bpm_delta=-20.0" in text, text
        assert "provenance_differences:" in text, text


if __name__ == "__main__":
    test_compare_generates_summary_files()
    print("compare-timing-paths smoke tests passed")
