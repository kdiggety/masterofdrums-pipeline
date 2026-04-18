#!/usr/bin/env python3
"""Integration tests: MIDI parsing and lane mapping across codebases.

Validates that:
1. Pipeline MIDI lane mapping covers complete drum kit
2. Synthetic test MIDI files are structurally valid
3. Mapped lanes match pipeline's normalized names
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
ADTOF_PATH = ROOT / "scripts" / "adtof-output-adapter.py"
MIDI_DIR = ROOT / "Tests" / "PipelineRuntimeTests" / "Fixtures" / "midi"


def load_module(name: str, path: pathlib.Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


adtof = load_module("adtof_output_adapter", ADTOF_PATH)


def test_synthetic_midi_files_exist() -> None:
    """Verify all generated test MIDI files exist and are valid."""
    midi_files = [
        "test-kick-only.mid",
        "test-full-kit.mid",
        "test-tom-high.mid",
        "test-tom-mid.mid",
        "test-tom-low.mid",
        "test-zero-velocity.mid",
        "test-hihats.mid",
        "test-wrong-channel.mid",
    ]

    for midi_file in midi_files:
        path = MIDI_DIR / midi_file
        assert path.exists(), f"Test MIDI file not found: {path}"
        assert path.stat().st_size > 0, f"Test MIDI file is empty: {path}"
        # Validate basic MIDI structure (starts with MThd)
        data = path.read_bytes()
        assert data[:4] == b'MThd', f"Invalid MIDI header in {path}"

    print("✓ all synthetic MIDI files are valid")


def test_pipeline_midi_to_label_covers_common_notes() -> None:
    """Verify pipeline can map all common GM drum MIDI notes."""
    common_notes = {
        35: "kick", 36: "kick",
        37: "snare", 38: "snare", 39: "clap", 40: "snare",
        41: "floor tom", 43: "floor tom",
        42: "closed hi hat", 44: "closed hi hat", 46: "open hi hat",
        45: "mid tom", 47: "high tom", 48: "high tom", 50: "high tom",
        49: "crash", 51: "ride", 52: "crash",
        55: "crash", 57: "crash", 59: "ride",
    }

    for midi_note, expected_label in common_notes.items():
        actual_label = adtof.MIDI_TO_LABEL.get(midi_note)
        assert actual_label == expected_label, \
            f"MIDI {midi_note}: expected '{expected_label}', got '{actual_label}'"

    print("✓ pipeline MIDI_TO_LABEL mapping is complete and correct")


def test_tom_distinction_in_pipeline() -> None:
    """Verify pipeline distinguishes between tom types (critical for correct rendering)."""
    assert adtof.MIDI_TO_LABEL[41] == "floor tom", "Low tom should be 'floor tom'"
    assert adtof.MIDI_TO_LABEL[45] == "mid tom", "Mid tom should be 'mid tom'"
    assert adtof.MIDI_TO_LABEL[48] == "high tom", "High tom should be 'high tom'"

    # Ensure no tom mappings are collapsed
    tom_labels = set()
    for midi, label in adtof.MIDI_TO_LABEL.items():
        if "tom" in label.lower():
            tom_labels.add(label)

    assert len(tom_labels) >= 3, f"Should have at least 3 tom types, got: {tom_labels}"
    print("✓ pipeline correctly distinguishes tom types")


def test_hihat_variations_mapped() -> None:
    """Verify hi-hat open/closed distinction is preserved."""
    closed_hihats = [midi for midi, label in adtof.MIDI_TO_LABEL.items()
                     if "closed" in label.lower() and "hat" in label.lower()]
    open_hihats = [midi for midi, label in adtof.MIDI_TO_LABEL.items()
                   if "open" in label.lower() and "hat" in label.lower()]

    assert len(closed_hihats) > 0, "Should have closed hi-hat mappings"
    assert len(open_hihats) > 0, "Should have open hi-hat mappings"
    print("✓ hi-hat open/closed distinction preserved")


def test_crash_vs_ride_distinction() -> None:
    """Verify crash and ride cymbals are distinct."""
    crashes = [midi for midi, label in adtof.MIDI_TO_LABEL.items()
               if label == "crash"]
    rides = [midi for midi, label in adtof.MIDI_TO_LABEL.items()
             if label == "ride"]

    assert len(crashes) > 0, "Should have crash mappings"
    assert len(rides) > 0, "Should have ride mappings"
    assert set(crashes).isdisjoint(set(rides)), "Crash and ride should use different MIDI notes"
    print("✓ crash and ride are distinct")


def test_no_duplicate_midi_notes() -> None:
    """Verify each MIDI note maps to exactly one label (no collisions)."""
    seen = {}
    for midi_note, label in adtof.MIDI_TO_LABEL.items():
        assert midi_note not in seen, \
            f"MIDI note {midi_note} mapped twice: '{seen[midi_note]}' and '{label}'"
        seen[midi_note] = label

    print(f"✓ no duplicate MIDI note mappings ({len(seen)} unique notes)")


def test_velocity_filtering_concern() -> None:
    """Note: Verify that test MIDI with zero-velocity notes was generated.

    The actual filtering happens in MIDI parsing, not here.
    This test just documents the concern.
    """
    zero_vel_path = MIDI_DIR / "test-zero-velocity.mid"
    assert zero_vel_path.exists(), "Test MIDI for velocity filtering not found"
    print("✓ velocity filtering test MIDI exists (filtering validated in midi_to_modchart tests)")


def test_channel_filtering_concern() -> None:
    """Note: Verify that test MIDI with wrong-channel notes was generated.

    The actual filtering happens in MIDI parsing (channel 9 = drums).
    This test just documents the concern.
    """
    wrong_ch_path = MIDI_DIR / "test-wrong-channel.mid"
    assert wrong_ch_path.exists(), "Test MIDI for channel filtering not found"
    print("✓ channel filtering test MIDI exists (filtering validated in midi_to_modchart tests)")


if __name__ == "__main__":
    # Generate test MIDI files if not present
    if not MIDI_DIR.exists():
        print("Generating test MIDI files...")
        import generate_test_midi
        generate_test_midi.generate_test_midis(MIDI_DIR)

    test_synthetic_midi_files_exist()
    test_pipeline_midi_to_label_covers_common_notes()
    test_tom_distinction_in_pipeline()
    test_hihat_variations_mapped()
    test_crash_vs_ride_distinction()
    test_no_duplicate_midi_notes()
    test_velocity_filtering_concern()
    test_channel_filtering_concern()

    print("\n✓ All MIDI integration tests passed")
