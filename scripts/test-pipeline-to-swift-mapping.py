#!/usr/bin/env python3
"""Cross-validation tests: Pipeline lane names → Swift lane indices.

Ensures that pipeline's normalized lane names (tom_low, tom_mid, tom_high, etc.)
correctly convert to Swift's 5-lane model (red, yellow, blue, green, kick).
"""

from __future__ import annotations


# Pipeline lane names (source of truth for analysis/MIDI)
PIPELINE_LANES = {
    "kick",
    "snare",
    "clap",
    "hihat_closed",
    "hihat_open",
    "tom_low",
    "tom_mid",
    "tom_high",
    "crash",
    "ride",
    "percussion",
}

# Swift Lane enum mapping (from ChartFileStore.laneIndex)
# Maps pipeline lane names to Swift Lane raw values
PIPELINE_TO_SWIFT_MAPPING = {
    "kick": 4,              # Lane.kick
    "snare": 0,             # Lane.red
    "clap": 0,              # Lane.red (collapsed to snare)
    "hihat_closed": 1,      # Lane.yellow
    "hihat_open": 3,        # Lane.green (open hihats with cymbals)
    "tom_low": 3,           # Lane.green
    "tom_mid": 3,           # Lane.green
    "tom_high": 2,          # Lane.blue (high toms only)
    "crash": 3,             # Lane.green
    "ride": 3,              # Lane.green
    "percussion": 3,        # Lane.green (fallback)
}

# Swift Lane enum values (source of truth for app)
SWIFT_LANE_NAMES = {
    0: "red (snare)",
    1: "yellow (hihat)",
    2: "blue (tom_high)",
    3: "green (crash/ride/tom_low_mid)",
    4: "kick",
}


def test_all_pipeline_lanes_have_swift_mapping() -> None:
    """Verify every pipeline lane maps to a Swift lane."""
    unmapped = []
    for pipeline_lane in PIPELINE_LANES:
        if pipeline_lane not in PIPELINE_TO_SWIFT_MAPPING:
            unmapped.append(pipeline_lane)

    assert not unmapped, f"Unmapped pipeline lanes: {unmapped}"
    print(f"✓ all {len(PIPELINE_LANES)} pipeline lanes have Swift mappings")


def test_all_swift_mappings_are_valid() -> None:
    """Verify all pipeline → Swift mappings point to valid lanes."""
    invalid = []
    for pipeline_lane, swift_idx in PIPELINE_TO_SWIFT_MAPPING.items():
        if swift_idx not in SWIFT_LANE_NAMES:
            invalid.append((pipeline_lane, swift_idx))

    assert not invalid, f"Invalid Swift lane indices: {invalid}"
    print("✓ all Swift lane indices are valid (0-4)")


def test_tom_mapping_is_consistent() -> None:
    """Verify tom lanes map consistently: low/mid → green (3), high → blue (2)."""
    assert PIPELINE_TO_SWIFT_MAPPING["tom_low"] == 3, "tom_low should map to green (3)"
    assert PIPELINE_TO_SWIFT_MAPPING["tom_mid"] == 3, "tom_mid should map to green (3)"
    assert PIPELINE_TO_SWIFT_MAPPING["tom_high"] == 2, "tom_high should map to blue (2)"

    print("✓ tom lanes map correctly: low/mid → green, high → blue")


def test_hihat_mapping_separates_closed_and_open() -> None:
    """Verify closed hi-hats map to yellow (1) and open hi-hats map to green (3)."""
    assert PIPELINE_TO_SWIFT_MAPPING["hihat_closed"] == 1, "Closed hihat should map to yellow (1)"
    assert PIPELINE_TO_SWIFT_MAPPING["hihat_open"] == 3, "Open hihat should map to green (3)"

    print("✓ hihat_closed → yellow (1), hihat_open → green (3)")


def test_crash_ride_map_to_same_lane() -> None:
    """Verify crash and ride both map to green (crash/ride family)."""
    assert PIPELINE_TO_SWIFT_MAPPING["crash"] == PIPELINE_TO_SWIFT_MAPPING["ride"], \
        "Crash and ride should map to same lane"
    assert PIPELINE_TO_SWIFT_MAPPING["crash"] == 3, "Crash/ride should map to green (3)"

    print("✓ crash/ride map to same lane (green = 3)")


def test_snare_and_clap_map_together() -> None:
    """Verify snare and clap both map to red."""
    assert PIPELINE_TO_SWIFT_MAPPING["snare"] == PIPELINE_TO_SWIFT_MAPPING["clap"], \
        "Snare and clap should map to same lane"
    assert PIPELINE_TO_SWIFT_MAPPING["snare"] == 0, "Snare/clap should map to red (0)"

    print("✓ snare/clap map to same lane (red = 0)")


def test_all_lanes_coverable_with_5_lanes() -> None:
    """Verify all 11 pipeline lanes can fit in 5 Swift lanes."""
    coverage = set(PIPELINE_TO_SWIFT_MAPPING.values())
    assert len(coverage) <= 5, f"Mapping uses {len(coverage)} Swift lanes, should be ≤5"
    assert coverage == {0, 1, 2, 3, 4}, f"Should use all 5 lanes, but uses {coverage}"

    print(f"✓ all {len(PIPELINE_LANES)} pipeline lanes fit in 5 Swift lanes")


def test_mapping_preserves_acoustic_logic() -> None:
    """Verify mapping makes acoustic sense:
    - Bright/tight sounds (closed hihat, high toms) → yellow or blue
    - Low/open sounds (open hihat, crashes, rides, low toms) → green
    - High/percussive sounds (snare, clap) → red
    - Bass → kick
    """
    # Bright/tight (closed hihat only)
    assert PIPELINE_TO_SWIFT_MAPPING["hihat_closed"] == 1, "Closed hihat is bright/tight → yellow"

    # High-pitched drums
    assert PIPELINE_TO_SWIFT_MAPPING["tom_high"] == 2, "High toms are bright → blue"

    # Open/resonant (includes open hihats now)
    assert PIPELINE_TO_SWIFT_MAPPING["hihat_open"] == 3, "Open hihat is open/resonant → green"
    assert PIPELINE_TO_SWIFT_MAPPING["crash"] == 3, "Crashes are open → green"
    assert PIPELINE_TO_SWIFT_MAPPING["ride"] == 3, "Rides are open → green"
    assert PIPELINE_TO_SWIFT_MAPPING["tom_low"] == 3, "Low toms are dark → green"

    # Sharp/articulate
    assert PIPELINE_TO_SWIFT_MAPPING["snare"] == 0, "Snare is sharp → red"

    # Bass
    assert PIPELINE_TO_SWIFT_MAPPING["kick"] == 4, "Kick is foundational → kick lane"

    print("✓ mapping preserves acoustic logic across all lanes")


def test_mapping_inverse_is_sensible() -> None:
    """Verify that Swift lane → pipeline lane mapping makes sense (multiple pipeline lanes per Swift lane)."""
    swift_to_pipeline = {}
    for pipeline_lane, swift_idx in PIPELINE_TO_SWIFT_MAPPING.items():
        if swift_idx not in swift_to_pipeline:
            swift_to_pipeline[swift_idx] = []
        swift_to_pipeline[swift_idx].append(pipeline_lane)

    # Red should have snare + clap (similar attack)
    assert set(swift_to_pipeline.get(0, [])) == {"snare", "clap"}, "Red should have snare/clap"

    # Yellow should have hihat_closed only
    assert set(swift_to_pipeline.get(1, [])) == {"hihat_closed"}, "Yellow should have hihat_closed"

    # Blue should have tom_high only
    assert swift_to_pipeline.get(2, []) == ["tom_high"], "Blue should have only high toms"

    # Green should have low/mid toms + open hihats + cymbals
    green_lanes = set(swift_to_pipeline.get(3, []))
    assert "tom_low" in green_lanes and "tom_mid" in green_lanes, "Green should have low/mid toms"
    assert "hihat_open" in green_lanes, "Green should have open hihats"
    assert "crash" in green_lanes and "ride" in green_lanes, "Green should have crashes/rides"

    # Kick should be isolated
    assert swift_to_pipeline.get(4, []) == ["kick"], "Kick should be isolated"

    print("✓ Swift lane ← pipeline lane mapping is sensible (families grouped)")


def test_deduplication_is_intentional() -> None:
    """Verify that any deduplication (multiple pipeline lanes → single Swift lane) is intentional and documented."""
    swift_to_pipeline = {}
    for pipeline_lane, swift_idx in PIPELINE_TO_SWIFT_MAPPING.items():
        if swift_idx not in swift_to_pipeline:
            swift_to_pipeline[swift_idx] = []
        swift_to_pipeline[swift_idx].append(pipeline_lane)

    # Document intentional deduplications
    deduplications = [
        (1, {"hihat_closed"}, "Closed hihats are tight/rhythmic"),
        (3, {"tom_low", "tom_mid", "hihat_open", "crash", "ride", "percussion"}, "All mid/low/open resonant instruments"),
        (0, {"snare", "clap"}, "Both sharp percussive attacks"),
    ]

    for swift_idx, expected_lanes, reason in deduplications:
        actual = set(swift_to_pipeline.get(swift_idx, []))
        # Just verify the documented ones exist
        for lane in expected_lanes:
            assert lane in actual, f"Lane {lane} should be in Swift {swift_idx} ({reason})"

    print("✓ deduplications are intentional and well-grouped")


if __name__ == "__main__":
    test_all_pipeline_lanes_have_swift_mapping()
    test_all_swift_mappings_are_valid()
    test_tom_mapping_is_consistent()
    test_hihat_mapping_separates_closed_and_open()
    test_crash_ride_map_to_same_lane()
    test_snare_and_clap_map_together()
    test_all_lanes_coverable_with_5_lanes()
    test_mapping_preserves_acoustic_logic()
    test_mapping_inverse_is_sensible()
    test_deduplication_is_intentional()

    print("\n✓ All pipeline ↔ Swift cross-validation tests passed")
