#!/usr/bin/env python3
"""Smoke tests for scripts/looperman-phase1-audit.py."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import json

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "looperman-phase1-audit.py"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


audit = load_module("looperman_phase1_audit", SCRIPT)

SAMPLE_PAYLOAD = {
    "status": "validation-passed",
    "repo": "masterofdrums-pipeline",
    "merge_readiness": {"go": True, "reason": "all required stages passed"},
    "validate_analyzer": [
        {
            "source": {"source_name": "clip-a", "source_uri": "file:///clip-a.wav"},
            "validation": {"imports_ok": True, "config_ok": True},
            "logs": [
                {
                    "stdout": '{"analysis":{"estimatedTempoBPM":120.0,"confidence":0.9,"runtimeBackend":"scripts/beat-this-backend.py","runtimeSelectedBackend":"primary+fallback-events","runtimeFallbackUsed":false},"warnings":["analyzer wrapper merged 12 fallback drum-event candidates onto primary timing output","event-backend: filtered 2 low-confidence snare candidates","event-backend: deduped 3 near-duplicate same-lane hits while keeping the stronger candidate"]}'
                }
            ],
        }
    ],
    "runs_final": [
        {
            "run_id": "run-a",
            "source_uri": "file:///clip-a.wav",
            "status": "completed",
            "artifacts": [
                {"type": "audio_analysis", "uri": "file:///audio.json"},
                {"type": "normalized_analysis", "uri": "file:///normalized.json"},
                {"type": "base_chart", "uri": "file:///base.json"},
                {"type": "final_chart", "uri": "file:///final.json"},
            ],
        }
    ],
}


def test_phase1_summary_extracts_dense_event_signals() -> None:
    summary = audit.phase1_summary(SAMPLE_PAYLOAD)
    assert summary["aggregate"]["sourceCount"] == 1, summary
    assert summary["aggregate"]["totalStage2CandidateCount"] == 12, summary
    assert summary["aggregate"]["totalFilteredCount"] == 2, summary
    assert summary["aggregate"]["totalDedupedCount"] == 3, summary
    source = summary["sources"][0]
    assert source["stage2Used"] is True, source
    assert source["selectedBackend"] == "primary+fallback-events", source
    assert source["runID"] == "run-a", source
    assert source["baseChartArtifact"] == "file:///base.json", source


def test_directory_mode_summarizes_validate_analyzer_results() -> None:
    with tempfile.TemporaryDirectory() as raw:
        tempdir = pathlib.Path(raw)
        payload = {
            "ok": True,
            "data": SAMPLE_PAYLOAD["validate_analyzer"][0],
        }
        (tempdir / "clip-a.json").write_text(json.dumps(payload), encoding="utf-8")
        summary = audit.from_validate_analyzer_directory(tempdir)
        assert summary["aggregate"]["sourceCount"] == 1, summary
        assert summary["sources"][0]["stage2CandidateCount"] == 12, summary


if __name__ == "__main__":
    test_phase1_summary_extracts_dense_event_signals()
    test_directory_mode_summarizes_validate_analyzer_results()
    print("looperman-phase1-audit tests passed")
