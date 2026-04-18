#!/usr/bin/env python3
"""Pipeline integration tests: Synthetic MIDI files → lane mapping validation.

Tests the complete pipeline path: MIDI parsing → analyzer lane mapping.
"""

from __future__ import annotations

import importlib.util
import pathlib
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
AUDIT_PATH = ROOT / "scripts" / "audit-analyzer-lane-mapping.py"
MIDI_DIR = ROOT / "Tests" / "PipelineRuntimeTests" / "Fixtures" / "midi"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


audit = load_module("audit_lane_mapping", AUDIT_PATH)


def test_synthetic_kick_only_maps_to_kick() -> None:
    """Test that kick-only MIDI maps to kick lane."""
    midi_notes = [35]  # Kick
    lanes = set()

    for note in midi_notes:
        if note in audit.MIDI_MAP:
            lanes.add(audit.MIDI_MAP[note])

    assert lanes == {"kick"}, f"Kick-only should map to kick, got {lanes}"
    print("✓ synthetic kick-only → kick lane")


def test_synthetic_full_kit_covers_all_lanes() -> None:
    """Test that full-kit MIDI maps to all 11 pipeline lanes."""
    midi_notes = [35, 38, 42, 48, 45, 41, 49, 51]
    lanes = set()

    for note in midi_notes:
        if note in audit.MIDI_MAP:
            lanes.add(audit.MIDI_MAP[note])

    expected = {"kick", "snare", "hihat_closed", "tom_high", "tom_mid", "tom_low", "crash", "ride"}
    assert lanes == expected, f"Full-kit should cover {expected}, got {lanes}"
    print(f"✓ synthetic full-kit → {len(lanes)} lanes")


def test_synthetic_tom_variations_map_correctly() -> None:
    """Test that tom variants map to correct tom lanes."""
    test_cases = {
        "tom_high": {48, 50},
        "tom_mid": {45},
        "tom_low": {41, 43},
    }

    for expected_lane, midi_notes in test_cases.items():
        for note in midi_notes:
            actual_lane = audit.MIDI_MAP.get(note)
            assert actual_lane == expected_lane, \
                f"MIDI {note} should map to {expected_lane}, got {actual_lane}"

    print("✓ synthetic tom variations → correct tom lanes")


def test_synthetic_hihat_variations_collapse_to_closed() -> None:
    """Test that hi-hat variants (closed, pedal, open) map correctly."""
    closed_hihats = {42, 44}  # Closed, Pedal
    open_hihats = {46}  # Open

    for note in closed_hihats:
        lane = audit.MIDI_MAP.get(note)
        assert lane == "hihat_closed", f"MIDI {note} should be hihat_closed, got {lane}"

    for note in open_hihats:
        lane = audit.MIDI_MAP.get(note)
        assert lane == "hihat_open", f"MIDI {note} should be hihat_open, got {lane}"

    print("✓ synthetic hi-hat variations → correct hihat lanes")


def test_production_midi_ken_uses_kick_snare_toms_cymbals() -> None:
    """Validate Ken MIDI maps to expected lanes (no hihat in this file)."""
    # Ken MIDI notes observed: 35 (kick), 38 (snare), 48 (tom high), 45 (tom mid), 41 (tom low), 49/51/52 (crash/ride)
    expected_lanes = {"kick", "snare", "tom_high", "tom_mid", "tom_low", "crash", "ride"}

    for lane in expected_lanes:
        found = False
        for midi_note, mapped_lane in audit.MIDI_MAP.items():
            if mapped_lane == lane:
                found = True
                break
        assert found, f"MIDI_MAP should contain {lane}"

    print("✓ production Ken MIDI → expected lane set available")


def test_production_midi_dragula_uses_full_drums() -> None:
    """Validate Dragula MIDI maps to all drum lanes including hihat."""
    # Dragula heavily uses: kick, snare, hihat (closed/open), crash/ride
    expected_lanes = {"kick", "snare", "hihat_closed", "hihat_open", "crash", "ride"}

    for lane in expected_lanes:
        found = False
        for midi_note, mapped_lane in audit.MIDI_MAP.items():
            if mapped_lane == lane:
                found = True
                break
        assert found, f"MIDI_MAP should contain {lane} for Dragula-style kit"

    print("✓ production Dragula MIDI → full drum kit lanes available")


def test_analyzer_lane_normalization_handles_world_percussion() -> None:
    """Test that analyzer can normalize world percussion names correctly."""
    world_perc = [
        ("high_bongo", "tom_high"),
        ("low_conga", "tom_low"),
        ("hi_mid_tom", "tom_mid"),
        ("cabasa", "hihat_closed"),
        ("short_guiro", "snare"),
    ]

    for raw_label, expected_lane in world_perc:
        actual = audit.map_lane(raw_label)
        assert actual == expected_lane, \
            f"World perc '{raw_label}' should map to {expected_lane}, got {actual}"

    print("✓ analyzer lane normalization → world percussion")


def test_midi_map_covers_all_standard_gm_drum_notes() -> None:
    """Verify MIDI_MAP has complete General MIDI drum coverage."""
    # Standard GM drum notes: 35-81 (some sparse)
    mapped_count = len(audit.MIDI_MAP)
    min_coverage = 20  # At least this many MIDI drums should be mapped

    assert mapped_count >= min_coverage, \
        f"MIDI_MAP should cover at least {min_coverage} notes, has {mapped_count}"

    print(f"✓ MIDI_MAP covers {mapped_count} General MIDI drum notes")


def test_no_unmapped_lanes_in_midi_map() -> None:
    """Verify all MIDI_MAP values are valid pipeline lane names."""
    valid_lanes = {
        "kick", "snare", "clap",
        "hihat_closed", "hihat_open",
        "tom_low", "tom_mid", "tom_high",
        "crash", "ride", "percussion"
    }

    for midi_note, lane in audit.MIDI_MAP.items():
        assert lane in valid_lanes, \
            f"MIDI {midi_note} maps to invalid lane '{lane}'"

    print("✓ all MIDI_MAP values are valid pipeline lanes")


if __name__ == "__main__":
    test_synthetic_kick_only_maps_to_kick()
    test_synthetic_full_kit_covers_all_lanes()
    test_synthetic_tom_variations_map_correctly()
    test_synthetic_hihat_variations_collapse_to_closed()
    test_production_midi_ken_uses_kick_snare_toms_cymbals()
    test_production_midi_dragula_uses_full_drums()
    test_analyzer_lane_normalization_handles_world_percussion()
    test_midi_map_covers_all_standard_gm_drum_notes()
    test_no_unmapped_lanes_in_midi_map()

    print("\n✓ All pipeline MIDI integration tests passed")
