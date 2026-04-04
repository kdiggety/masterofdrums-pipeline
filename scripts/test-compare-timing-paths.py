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
    "'drumEvents': ["
    "  {'eventID': 'p-kick-1', 'onsetSeconds': 0.0, 'lane': 'kick', 'label': 'kick', 'confidence': 0.91, 'sourceLabel': 'heuristic_backend'}, "
    "  {'eventID': 'p-snare-1', 'onsetSeconds': 0.5, 'lane': 'snare', 'label': 'snare', 'confidence': 0.72, 'sourceLabel': 'heuristic_backend'}, "
    "  {'eventID': 'p-hat-1', 'onsetSeconds': 1.0, 'lane': 'closed_hihat', 'label': 'closed hi hat', 'confidence': 0.42, 'sourceLabel': 'heuristic_backend'}"
    "], "
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
    "'drumEvents': ["
    "  {'eventID': 'f-kick-1', 'onsetSeconds': 0.0, 'lane': 'kick', 'label': 'kick', 'confidence': 0.95, 'sourceLabel': 'ml_backend'}, "
    "  {'eventID': 'f-snare-1', 'onsetSeconds': 0.56, 'lane': 'snare', 'label': 'snare', 'confidence': 0.83, 'sourceLabel': 'ml_backend'}, "
    "  {'eventID': 'f-tom-1', 'onsetSeconds': 1.2, 'lane': 'tom', 'label': 'tom', 'confidence': 0.61, 'sourceLabel': 'ml_backend'}, "
    "  {'eventID': 'f-kick-2', 'onsetSeconds': 1.9, 'lane': 'kick', 'label': 'kick', 'confidence': 0.49, 'sourceLabel': 'ml_backend'}"
    "], "
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
        assert summary["delta"]["analysisConfidence"]["delta"] == -0.2, summary
        assert summary["delta"]["beatGrid"]["beatStarts"]["mismatchCount"] == 4, summary
        assert summary["delta"]["segments"]["boundaries"]["mismatchCount"] == 1, summary
        assert summary["primary"]["eventLaneCounts"] == {"closed_hihat": 1, "kick": 1, "snare": 1}, summary
        assert summary["fallback"]["eventLaneCounts"] == {"kick": 2, "snare": 1, "tom": 1}, summary
        assert summary["delta"]["events"]["countDelta"] == 1, summary
        assert summary["delta"]["events"]["laneCounts"]["differenceCount"] == 3, summary
        assert summary["delta"]["events"]["sourceCounts"]["differenceCount"] == 2, summary
        assert summary["delta"]["events"]["confidenceCounts"]["differenceCount"] == 1, summary
        assert summary["delta"]["events"]["onsets"]["matchCount"] == 1, summary
        assert summary["delta"]["events"]["onsets"]["matchedButShiftedCount"] == 0, summary
        assert summary["delta"]["events"]["onsets"]["primaryOnlyCount"] == 2, summary
        assert summary["delta"]["events"]["onsets"]["fallbackOnlyCount"] == 3, summary
        assert summary["delta"]["provenance"]["selectedBackend"] == {"primary": "primary", "fallback": "fallback"}, summary
        assert summary["delta"]["provenance"]["fallbackUsed"] == {"primary": False, "fallback": True}, summary

        text = text_path.read_text(encoding="utf-8")
        assert "timing path comparison" in text, text
        assert "tempo_bpm_delta=-20.0" in text, text
        assert "event_count_delta=1" in text, text
        assert "event_lane_difference_preview:" in text, text
        assert "provenance_differences:" in text, text


if __name__ == "__main__":
    test_compare_generates_summary_files()
    print("compare-timing-paths smoke tests passed")
