#!/usr/bin/env python3
"""Regression checks for analyzer lane alias/MIDI mapping helpers."""

from __future__ import annotations

import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
AUDIT_PATH = ROOT / "scripts" / "audit-analyzer-lane-mapping.py"
ADTOF_PATH = ROOT / "scripts" / "adtof-output-adapter.py"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


audit = load_module("audit_lane_mapping", AUDIT_PATH)
adtof = load_module("adtof_output_adapter", ADTOF_PATH)


def test_expanded_alias_mapping_covers_high_value_lane_variants() -> None:
    expectations = {
        "kickdrum": "kick",
        "snare drum": "snare",
        "closed hi hat edge": "hihat_closed",
        "half open hi hat": "hihat_open",
        "rack tom 1": "tom_high",
        "rack tom 2": "tom_mid",
        "low floor tom": "tom_low",
        "china cymbal": "crash",
        "splash cymbal": "crash",
    }
    for raw, expected in expectations.items():
        actual = audit.map_lane(raw)
        assert actual == expected, (raw, actual, expected)


def test_adtof_adapter_maps_common_gm_lane_notes() -> None:
    expectations = {
        37: "snare",
        40: "snare",
        50: "high tom",
        52: "crash",
        55: "crash",
    }
    for midi, expected in expectations.items():
        actual = adtof.MIDI_TO_LABEL[midi]
        assert actual == expected, (midi, actual, expected)


def test_adtof_midi_kick_coverage() -> None:
    """Kick drums should all map to 'kick'."""
    for midi in [35, 36]:
        assert adtof.MIDI_TO_LABEL[midi] == "kick", f"MIDI {midi} should be kick"


def test_adtof_midi_snare_coverage() -> None:
    """Snare/clap family should map correctly."""
    snare_notes = [37, 38, 40]
    for midi in snare_notes:
        assert adtof.MIDI_TO_LABEL[midi] == "snare", f"MIDI {midi} should be snare"
    assert adtof.MIDI_TO_LABEL[39] == "clap", "MIDI 39 should be clap"


def test_adtof_midi_hihat_coverage() -> None:
    """Hi-hat variations should map correctly."""
    assert adtof.MIDI_TO_LABEL[42] == "closed hi hat"
    assert adtof.MIDI_TO_LABEL[44] == "closed hi hat"
    assert adtof.MIDI_TO_LABEL[46] == "open hi hat"


def test_adtof_midi_tom_coverage() -> None:
    """Toms should be correctly classified by pitch."""
    assert adtof.MIDI_TO_LABEL[41] == "floor tom", "MIDI 41 should be floor tom (low)"
    assert adtof.MIDI_TO_LABEL[43] == "floor tom", "MIDI 43 should be floor tom (low)"
    assert adtof.MIDI_TO_LABEL[45] == "mid tom", "MIDI 45 should be mid tom"
    assert adtof.MIDI_TO_LABEL[47] == "high tom", "MIDI 47 should be high tom"
    assert adtof.MIDI_TO_LABEL[48] == "high tom", "MIDI 48 should be high tom"
    assert adtof.MIDI_TO_LABEL[50] == "high tom", "MIDI 50 should be high tom"


def test_adtof_midi_cymbal_coverage() -> None:
    """Cymbals and percussion should map to crash/ride."""
    crash_notes = [49, 52, 55, 57]
    ride_notes = [51, 53, 59]
    for midi in crash_notes:
        assert adtof.MIDI_TO_LABEL[midi] == "crash", f"MIDI {midi} should be crash"
    for midi in ride_notes:
        assert adtof.MIDI_TO_LABEL[midi] == "ride", f"MIDI {midi} should be ride"


def test_adtof_midi_complete_drum_kit() -> None:
    """Verify all mapped MIDI notes cover a complete drum kit without gaps."""
    mapped_notes = set(adtof.MIDI_TO_LABEL.keys())

    expected_coverage = {
        "kick": {35, 36},
        "snare": {37, 38, 40},
        "clap": {39},
        "closed hi hat": {42, 44},
        "open hi hat": {46},
        "floor tom": {41, 43},
        "mid tom": {45},
        "high tom": {47, 48, 50},
        "crash": {49, 52, 55, 57},
        "ride": {51, 53, 59},
        "percussion": {60},
    }

    # Build actual coverage from mapping
    actual_coverage = {}
    for midi, label in adtof.MIDI_TO_LABEL.items():
        if label not in actual_coverage:
            actual_coverage[label] = set()
        actual_coverage[label].add(midi)

    # Verify coverage matches expectations
    for label, expected_notes in expected_coverage.items():
        actual_notes = actual_coverage.get(label, set())
        assert actual_notes == expected_notes, \
            f"Label '{label}' coverage mismatch: expected {expected_notes}, got {actual_notes}"


if __name__ == "__main__":
    test_expanded_alias_mapping_covers_high_value_lane_variants()
    test_adtof_adapter_maps_common_gm_lane_notes()
    test_adtof_midi_kick_coverage()
    test_adtof_midi_snare_coverage()
    test_adtof_midi_hihat_coverage()
    test_adtof_midi_tom_coverage()
    test_adtof_midi_cymbal_coverage()
    test_adtof_midi_complete_drum_kit()
    print("analyzer lane mapping tests passed")
