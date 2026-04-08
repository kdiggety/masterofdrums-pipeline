#!/usr/bin/env python3

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "chart-summary.py"


def run_summary(payload: dict) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(payload, handle)
        temp_path = Path(handle.name)
    try:
        completed = subprocess.run(
            ["python3", str(SCRIPT), str(temp_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(completed.stdout)
    finally:
        temp_path.unlink(missing_ok=True)


pipeline_payload = {
    "chart": {
        "notes": [
            {"noteID": "1", "lane": "kick", "startSeconds": 0.02},
            {"noteID": "2", "lane": "snare", "startSeconds": 0.62},
            {"noteID": "3", "lane": "closed_hihat", "startSeconds": 1.22},
        ]
    },
    "timing": {"bpm": 120, "offsetSeconds": 0},
    "source": {"title": "Fixture Song", "sourceAudio": "/tmp/fixture.wav"},
}

legacy_payload = {
    "title": "Legacy Chart",
    "notes": [
        {"id": "1", "lane": 0, "time": 0.0, "label": "Kick"},
        {"id": "2", "lane": 1, "time": 0.5, "label": "Snare"},
    ],
}

pipeline_summary = run_summary(pipeline_payload)
assert pipeline_summary["noteCount"] == 3, pipeline_summary
assert pipeline_summary["uniqueLanes"] == ["closed_hihat", "kick", "snare"], pipeline_summary
assert pipeline_summary["laneCounts"] == {"closed_hihat": 1, "kick": 1, "snare": 1}, pipeline_summary
assert pipeline_summary["title"] == "Fixture Song", pipeline_summary
assert pipeline_summary["sampleNotes"][0]["time"] == 0.02, pipeline_summary

legacy_summary = run_summary(legacy_payload)
assert legacy_summary["noteCount"] == 2, legacy_summary
assert legacy_summary["title"] == "Legacy Chart", legacy_summary
assert legacy_summary["sampleNotes"][0]["time"] == 0.0, legacy_summary

print("chart-summary tests passed")
