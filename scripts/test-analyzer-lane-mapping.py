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


if __name__ == "__main__":
    test_expanded_alias_mapping_covers_high_value_lane_variants()
    test_adtof_adapter_maps_common_gm_lane_notes()
    print("analyzer lane mapping tests passed")
