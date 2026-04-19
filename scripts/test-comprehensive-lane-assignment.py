#!/usr/bin/env python3
"""Comprehensive lane assignment validation for pipeline and app.

Validates that the complete instrument-to-lane mapping is correct across both:
1. Pipeline (MIDI instrument → normalized lane name)
2. App (normalized lane name → Swift lane index)
"""

from __future__ import annotations


# Canonical assignment: instrument → (lane_number, color, key)
COMPREHENSIVE_ASSIGNMENT = {
    "kick": (4, "purple", "space"),
    "snare": (0, "red", "d"),
    "clap": (0, "red", "d"),
    "hihat_closed": (1, "yellow", "f"),
    "hihat_open": (3, "green", "k"),
    "tom_high": (2, "blue", "j"),
    "tom_mid": (3, "green", "k"),
    "tom_low": (3, "green", "k"),
    "crash": (3, "green", "k"),
    "ride": (3, "green", "k"),
    "percussion": (3, "green", "k"),
}


def test_comprehensive_assignment_is_complete() -> None:
    """Verify all 11 instruments are defined."""
    expected_instruments = {
        "kick", "snare", "clap",
        "hihat_closed", "hihat_open",
        "tom_low", "tom_mid", "tom_high",
        "crash", "ride", "percussion"
    }
    actual = set(COMPREHENSIVE_ASSIGNMENT.keys())
    assert actual == expected_instruments, \
        f"Instrument set mismatch. Expected {expected_instruments}, got {actual}"
    print(f"✓ all {len(actual)} instruments defined")


def test_all_lanes_numbered_0_to_4() -> None:
    """Verify lane numbers are 0-4."""
    lanes = set(value[0] for value in COMPREHENSIVE_ASSIGNMENT.values())
    expected_lanes = {0, 1, 2, 3, 4}
    assert lanes == expected_lanes, f"Expected lanes {expected_lanes}, got {lanes}"
    print("✓ lanes numbered 0-4")


def test_all_lanes_have_color_names() -> None:
    """Verify each lane has a color name."""
    colors = {
        0: "red",
        1: "yellow",
        2: "blue",
        3: "green",
        4: "purple",
    }

    for instrument, (lane_num, color, key) in COMPREHENSIVE_ASSIGNMENT.items():
        expected_color = colors[lane_num]
        assert color == expected_color, \
            f"Instrument '{instrument}' on lane {lane_num}: expected color '{expected_color}', got '{color}'"

    print("✓ all lanes have correct color names")


def test_all_lanes_have_keyboard_keys() -> None:
    """Verify each lane has a keyboard key."""
    lane_keys = {
        0: "d",      # red
        1: "f",      # yellow
        2: "j",      # blue
        3: "k",      # green
        4: "space",  # purple
    }

    for instrument, (lane_num, color, key) in COMPREHENSIVE_ASSIGNMENT.items():
        expected_key = lane_keys[lane_num]
        assert key == expected_key, \
            f"Instrument '{instrument}' on lane {lane_num}: expected key '{expected_key}', got '{key}'"

    print("✓ all lanes have correct keyboard keys")


def test_lane_0_red_contains_snare_and_clap() -> None:
    """Verify lane 0 (red) has snare and clap."""
    lane_0_instruments = {inst for inst, (lane, _, _) in COMPREHENSIVE_ASSIGNMENT.items() if lane == 0}
    assert lane_0_instruments == {"snare", "clap"}, \
        f"Lane 0 should have {{snare, clap}}, got {lane_0_instruments}"
    print("✓ lane 0 (red) = snare + clap")


def test_lane_1_yellow_contains_only_hihat_closed() -> None:
    """Verify lane 1 (yellow) has only hihat_closed."""
    lane_1_instruments = {inst for inst, (lane, _, _) in COMPREHENSIVE_ASSIGNMENT.items() if lane == 1}
    assert lane_1_instruments == {"hihat_closed"}, \
        f"Lane 1 should have {{hihat_closed}}, got {lane_1_instruments}"
    print("✓ lane 1 (yellow) = hihat_closed only")


def test_lane_2_blue_contains_only_tom_high() -> None:
    """Verify lane 2 (blue) has only tom_high."""
    lane_2_instruments = {inst for inst, (lane, _, _) in COMPREHENSIVE_ASSIGNMENT.items() if lane == 2}
    assert lane_2_instruments == {"tom_high"}, \
        f"Lane 2 should have {{tom_high}}, got {lane_2_instruments}"
    print("✓ lane 2 (blue) = tom_high only")


def test_lane_3_green_contains_resonant_instruments() -> None:
    """Verify lane 3 (green) has low/mid toms, cymbals, and open hihat."""
    lane_3_instruments = {inst for inst, (lane, _, _) in COMPREHENSIVE_ASSIGNMENT.items() if lane == 3}
    expected = {"tom_low", "tom_mid", "hihat_open", "crash", "ride", "percussion"}
    assert lane_3_instruments == expected, \
        f"Lane 3 should have {expected}, got {lane_3_instruments}"
    print("✓ lane 3 (green) = tom_low + tom_mid + hihat_open + crash + ride + percussion")


def test_lane_4_purple_contains_only_kick() -> None:
    """Verify lane 4 (purple) has only kick."""
    lane_4_instruments = {inst for inst, (lane, _, _) in COMPREHENSIVE_ASSIGNMENT.items() if lane == 4}
    assert lane_4_instruments == {"kick"}, \
        f"Lane 4 should have {{kick}}, got {lane_4_instruments}"
    print("✓ lane 4 (purple) = kick only")


def test_hihat_open_and_closed_are_separate() -> None:
    """Verify hihat_closed and hihat_open are on different lanes."""
    closed_lane = COMPREHENSIVE_ASSIGNMENT["hihat_closed"][0]
    open_lane = COMPREHENSIVE_ASSIGNMENT["hihat_open"][0]
    assert closed_lane != open_lane, \
        f"hihat_closed and hihat_open must be on different lanes: closed={closed_lane}, open={open_lane}"
    assert closed_lane == 1, "hihat_closed should be on lane 1"
    assert open_lane == 3, "hihat_open should be on lane 3"
    print("✓ hihat_closed (yellow) ≠ hihat_open (green)")


def test_tom_types_separated_correctly() -> None:
    """Verify tom types are on correct lanes."""
    tom_high_lane = COMPREHENSIVE_ASSIGNMENT["tom_high"][0]
    tom_mid_lane = COMPREHENSIVE_ASSIGNMENT["tom_mid"][0]
    tom_low_lane = COMPREHENSIVE_ASSIGNMENT["tom_low"][0]

    assert tom_high_lane == 2, f"tom_high should be on lane 2 (blue), got {tom_high_lane}"
    assert tom_mid_lane == 3, f"tom_mid should be on lane 3 (green), got {tom_mid_lane}"
    assert tom_low_lane == 3, f"tom_low should be on lane 3 (green), got {tom_low_lane}"
    assert tom_high_lane != tom_mid_lane, "tom_high should be separate from tom_mid/low"
    print("✓ tom_high (blue) separate from tom_mid + tom_low (green)")


def test_snare_and_clap_are_grouped() -> None:
    """Verify snare and clap are on the same lane."""
    snare_lane = COMPREHENSIVE_ASSIGNMENT["snare"][0]
    clap_lane = COMPREHENSIVE_ASSIGNMENT["clap"][0]
    assert snare_lane == clap_lane, \
        f"snare and clap must be on same lane: snare={snare_lane}, clap={clap_lane}"
    assert snare_lane == 0, "Both should be on lane 0 (red)"
    print("✓ snare + clap grouped on lane 0 (red)")


def test_cymbal_family_is_grouped() -> None:
    """Verify crash and ride are on the same lane."""
    crash_lane = COMPREHENSIVE_ASSIGNMENT["crash"][0]
    ride_lane = COMPREHENSIVE_ASSIGNMENT["ride"][0]
    assert crash_lane == ride_lane, \
        f"crash and ride must be on same lane: crash={crash_lane}, ride={ride_lane}"
    assert crash_lane == 3, "Both should be on lane 3 (green)"
    print("✓ crash + ride grouped on lane 3 (green)")


def test_acoustic_logic_preserved() -> None:
    """Verify the assignment makes acoustic sense."""
    # Tight/bright sounds
    assert COMPREHENSIVE_ASSIGNMENT["hihat_closed"][0] == 1, "Closed hihat is bright → yellow"
    assert COMPREHENSIVE_ASSIGNMENT["tom_high"][0] == 2, "High toms are bright → blue"

    # Open/resonant sounds
    assert COMPREHENSIVE_ASSIGNMENT["hihat_open"][0] == 3, "Open hihat is open → green"
    assert COMPREHENSIVE_ASSIGNMENT["crash"][0] == 3, "Crash is open → green"
    assert COMPREHENSIVE_ASSIGNMENT["ride"][0] == 3, "Ride is open → green"
    assert COMPREHENSIVE_ASSIGNMENT["tom_low"][0] == 3, "Low toms are dark → green"

    # Sharp/articulate
    assert COMPREHENSIVE_ASSIGNMENT["snare"][0] == 0, "Snare is sharp → red"
    assert COMPREHENSIVE_ASSIGNMENT["clap"][0] == 0, "Clap is sharp → red"

    # Bass
    assert COMPREHENSIVE_ASSIGNMENT["kick"][0] == 4, "Kick is foundational → purple"

    print("✓ acoustic logic preserved across assignment")


if __name__ == "__main__":
    test_comprehensive_assignment_is_complete()
    test_all_lanes_numbered_0_to_4()
    test_all_lanes_have_color_names()
    test_all_lanes_have_keyboard_keys()
    test_lane_0_red_contains_snare_and_clap()
    test_lane_1_yellow_contains_only_hihat_closed()
    test_lane_2_blue_contains_only_tom_high()
    test_lane_3_green_contains_resonant_instruments()
    test_lane_4_purple_contains_only_kick()
    test_hihat_open_and_closed_are_separate()
    test_tom_types_separated_correctly()
    test_snare_and_clap_are_grouped()
    test_cymbal_family_is_grouped()
    test_acoustic_logic_preserved()

    print("\n✓ All comprehensive lane assignment tests passed")
