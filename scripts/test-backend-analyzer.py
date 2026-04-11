#!/usr/bin/env python3
"""Focused unit-ish tests for scripts/backend-analyzer.py heuristic drum-event shaping."""

from __future__ import annotations

import importlib.util
import math
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT / "scripts" / "backend-analyzer.py"

spec = importlib.util.spec_from_file_location("backend_analyzer", MODULE_PATH)
backend = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(backend)


SAMPLE_RATE = backend.TARGET_SAMPLE_RATE


def event(onset: float, lane: str, confidence: float) -> tuple[float, str, str, float]:
    label = {
        "kick": "kick",
        "snare": "snare",
        "closed_hihat": "closed hi hat",
        "open_hihat": "open hi hat",
        "crash": "crash",
    }[lane]
    return (onset, lane, label, confidence)


def write_window(samples: list[float], onset_seconds: float, values: list[float]) -> None:
    start = int(onset_seconds * SAMPLE_RATE)
    for index, value in enumerate(values):
        position = start + index
        if 0 <= position < len(samples):
            samples[position] = value


def make_synthetic_samples(onset_seconds: float, window_seconds: float = 0.18) -> list[float]:
    length = int((onset_seconds + window_seconds) * SAMPLE_RATE) + 32
    return [0.0] * length


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


def test_preserves_fast_kick_doubles_when_spacing_is_intentional() -> None:
    shaped, warnings = backend.shape_drum_events(
        [
            event(0.000, "kick", 0.82),
            event(0.095, "kick", 0.79),
            event(0.500, "snare", 0.84),
        ],
        beats=[0.0, 0.5, 1.0],
    )
    assert [item["lane"] for item in shaped] == ["kick", "kick", "snare"], shaped
    assert not any("deduped" in warning for warning in warnings), warnings


def test_keeps_dense_hihat_triplet_texture() -> None:
    shaped, _ = backend.shape_drum_events(
        [
            event(0.000, "kick", 0.86),
            event(0.160, "closed_hihat", 0.84),
            event(0.245, "closed_hihat", 0.81),
            event(0.330, "closed_hihat", 0.83),
            event(0.500, "snare", 0.88),
        ],
        beats=[0.0, 0.5, 1.0],
    )
    assert [item["lane"] for item in shaped] == ["kick", "closed_hihat", "closed_hihat", "closed_hihat", "snare"], shaped


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


def test_classifies_sustained_noisy_hit_as_crash() -> None:
    onset = 0.1
    samples = make_synthetic_samples(onset)
    crash = []
    for index in range(1600):
        envelope = max(0.0, 1.0 - (index / 1800.0))
        base = (1 if index % 2 == 0 else -1) * 0.8 * envelope
        shimmer = ((1 if index % 3 == 0 else -1) * 0.25 + (1 if index % 5 == 0 else -1) * 0.15) * envelope
        crash.append(base + shimmer)
    write_window(samples, onset, crash)

    lane, label, confidence = backend.classify_event(samples, SAMPLE_RATE, onset)
    assert lane == "crash", (lane, label, confidence)
    assert label == "crash", (lane, label, confidence)
    assert confidence >= 0.7, (lane, label, confidence)


def test_classifies_sustained_bright_hit_as_open_hihat() -> None:
    onset = 0.1
    samples = make_synthetic_samples(onset)
    open_hat = []
    for index in range(1500):
        envelope = max(0.0, 1.0 - (index / 1800.0))
        value = envelope * ((0.55 if index % 4 in (0, 1) else -0.55) + (0.1 if index % 9 < 4 else -0.1))
        open_hat.append(value)
    write_window(samples, onset, open_hat)

    lane, label, confidence = backend.classify_event(samples, SAMPLE_RATE, onset)
    assert lane == "open_hihat", (lane, label, confidence)
    assert label == "open hi hat", (lane, label, confidence)
    assert confidence >= 0.6, (lane, label, confidence)


if __name__ == "__main__":
    test_prefers_stronger_same_lane_hit_when_deduping()
    test_preserves_fast_kick_doubles_when_spacing_is_intentional()
    test_keeps_dense_hihat_triplet_texture()
    test_promotes_beat_anchored_hits_to_kick_when_no_kick_detected()
    test_filters_weak_isolated_hihat_texture_but_keeps_strong_upbeat()
    test_classifies_sustained_noisy_hit_as_crash()
    test_classifies_sustained_bright_hit_as_open_hihat()
    print("backend-analyzer heuristic tests passed")
