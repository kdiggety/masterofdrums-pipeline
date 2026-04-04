#!/usr/bin/env python3
"""Focused unit-ish tests for scripts/backend-analyzer.py heuristic drum-event shaping."""

from __future__ import annotations

import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "backend-analyzer.py"

spec = importlib.util.spec_from_file_location("backend_analyzer", MODULE_PATH)
backend = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(backend)


def event(onset: float, lane: str, confidence: float) -> tuple[float, str, str, float]:
    label = {
        "kick": "kick",
        "snare": "snare",
        "closed_hihat": "closed hi hat",
    }[lane]
    return (onset, lane, label, confidence)


def test_prefers_stronger_same_lane_hit_when_deduping() -> None:
    shaped, warnings = backend.shape_drum_events(
        [
            event(0.000, "kick", 0.62),
            event(0.070, "kick", 0.91),
            event(0.500, "snare", 0.80),
        ],
        beats=[0.0, 0.5, 1.0],
    )
    assert [item["lane"] for item in shaped] == ["kick", "snare"], shaped
    assert shaped[0]["confidence"] == 0.91, shaped
    assert any("deduped" in warning for warning in warnings), warnings


def test_promotes_beat_anchored_hits_to_kick_when_no_kick_detected() -> None:
    shaped, warnings = backend.shape_drum_events(
        [
            event(0.00, "snare", 0.76),
            event(0.50, "snare", 0.84),
            event(1.00, "snare", 0.79),
            event(1.50, "snare", 0.83),
        ],
        beats=[0.0, 0.5, 1.0, 1.5, 2.0],
    )
    assert [item["lane"] for item in shaped] == ["kick", "snare", "kick", "snare"], shaped
    assert any("promoted" in warning for warning in warnings), warnings


def test_filters_weak_isolated_hihat_texture_but_keeps_strong_upbeat() -> None:
    shaped, warnings = backend.shape_drum_events(
        [
            event(0.00, "kick", 0.88),
            event(0.125, "closed_hihat", 0.69),
            event(0.25, "closed_hihat", 0.83),
            event(0.50, "snare", 0.86),
        ],
        beats=[0.0, 0.5, 1.0],
    )
    assert [item["lane"] for item in shaped] == ["kick", "closed_hihat", "snare"], shaped
    assert [item["onsetSeconds"] for item in shaped] == [0.0, 0.25, 0.5], shaped
    assert any("hi-hat" in warning for warning in warnings), warnings


if __name__ == "__main__":
    test_prefers_stronger_same_lane_hit_when_deduping()
    test_promotes_beat_anchored_hits_to_kick_when_no_kick_detected()
    test_filters_weak_isolated_hihat_texture_but_keeps_strong_upbeat()
    print("backend-analyzer heuristic tests passed")
