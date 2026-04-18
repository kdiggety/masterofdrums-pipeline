#!/usr/bin/env python3
"""Generate synthetic MIDI files for testing ADTOF adapter and pipeline lane mapping.

Creates minimal valid MIDI files with specific drum patterns to exercise:
- MIDI parsing (VLQ, running status, delta time)
- Note filtering (channel 9, velocity > 0)
- Lane mapping across all drum kit types
"""

from __future__ import annotations

import struct
from pathlib import Path
from typing import Optional


def write_vlq(value: int) -> bytes:
    """Encode variable-length quantity (MIDI format)."""
    result = bytearray()
    result.append(value & 0x7F)
    value >>= 7
    while value > 0:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(result))


def write_meta_event(meta_type: int, data: bytes) -> bytes:
    """Write a MIDI meta event: FF <type> <length> <data>."""
    return b'\xFF' + bytes([meta_type]) + write_vlq(len(data)) + data


def write_sysex_event(data: bytes) -> bytes:
    """Write a MIDI sysex event: F0 <length> <data> F7."""
    return b'\xF0' + write_vlq(len(data) + 1) + data + b'\xF7'


def write_note_on(channel: int, note: int, velocity: int, delta_ticks: int = 0) -> bytes:
    """Write a note-on event: <delta> <status> <note> <velocity>."""
    status = 0x90 | (channel & 0x0F)
    return write_vlq(delta_ticks) + bytes([status, note & 0x7F, velocity & 0x7F])


def write_note_off(channel: int, note: int, delta_ticks: int = 0) -> bytes:
    """Write a note-off event: <delta> <status> <note> <velocity>."""
    status = 0x80 | (channel & 0x0F)
    return write_vlq(delta_ticks) + bytes([status, note & 0x7F, 0])


def write_tempo_meta(tempo_us: int, delta_ticks: int = 0) -> bytes:
    """Write a tempo meta event (microseconds per beat)."""
    return write_vlq(delta_ticks) + write_meta_event(0x51, struct.pack(">I", tempo_us)[1:])


def write_time_signature_meta(num: int, denom: int, delta_ticks: int = 0) -> bytes:
    """Write a time signature meta event."""
    denom_power = 0
    d = denom
    while d > 1:
        denom_power += 1
        d >>= 1
    return write_vlq(delta_ticks) + write_meta_event(0x58, bytes([num, denom_power, 24, 8]))


def write_end_of_track() -> bytes:
    """Write end-of-track meta event."""
    return write_vlq(0) + write_meta_event(0x2F, b'')


def create_midi_file(name: str, notes_by_channel: dict[int, list[tuple[int, int, int]]]) -> bytes:
    """Create a MIDI file with drum notes.

    Args:
        name: Track name
        notes_by_channel: {channel: [(note, velocity, start_tick), ...]}

    Returns:
        Complete MIDI file bytes
    """
    # Build track data
    track_data = bytearray()

    # Sequence/track name
    track_data.extend(write_vlq(0))
    track_data.extend(write_meta_event(0x03, name.encode('latin1')))

    # Tempo (120 BPM = 500,000 microseconds per beat)
    track_data.extend(write_tempo_meta(500000))

    # Time signature (4/4)
    track_data.extend(write_time_signature_meta(4, 4))

    # Collect and sort all events by tick
    events: list[tuple[int, bytes]] = []
    for channel, notes in notes_by_channel.items():
        for note, velocity, tick in notes:
            events.append((tick, write_note_on(channel, note, velocity)))
            # Note-off after a short duration (24 ticks = 16th note at 480 ticks/beat)
            events.append((tick + 24, write_note_off(channel, note)))

    events.sort()

    # Write events with proper delta times
    last_tick = 0
    for tick, event in events:
        delta = tick - last_tick
        # Prepend correct delta time
        event_with_delta = write_vlq(delta) + event[len(write_vlq(0)):]
        track_data.extend(event_with_delta)
        last_tick = tick

    # End of track
    track_data.extend(write_end_of_track())

    # Build MIDI file
    midi = bytearray()

    # Header: MThd <length=6> <format> <tracks> <ticks_per_beat>
    midi.extend(b'MThd')
    midi.extend(struct.pack(">I", 6))
    midi.extend(struct.pack(">H", 0))  # Format 0
    midi.extend(struct.pack(">H", 1))  # One track
    midi.extend(struct.pack(">H", 480))  # Ticks per beat

    # Track: MTrk <length> <data>
    midi.extend(b'MTrk')
    midi.extend(struct.pack(">I", len(track_data)))
    midi.extend(track_data)

    return bytes(midi)


def generate_test_midis(output_dir: Path) -> None:
    """Generate all test MIDI files."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # Test 1: Simple kick drum (validates basic parsing)
    kick_only = create_midi_file("Kick Only", {9: [(35, 100, 0), (35, 100, 480), (35, 100, 960)]})
    (output_dir / "test-kick-only.mid").write_bytes(kick_only)

    # Test 2: Complete drum kit (all drum types)
    full_kit = create_midi_file("Full Kit", {
        9: [
            (35, 100, 0),      # Kick
            (38, 90, 240),     # Snare
            (42, 85, 360),     # Hi-hat closed
            (48, 80, 480),     # Tom high
            (45, 75, 600),     # Tom mid
            (41, 70, 720),     # Tom low (floor tom)
            (49, 95, 840),     # Crash
            (51, 85, 960),     # Ride
        ]
    })
    (output_dir / "test-full-kit.mid").write_bytes(full_kit)

    # Test 3: Each tom type separately (validates tom classification)
    tom_high = create_midi_file("Tom High", {9: [(48, 90, tick) for tick in range(0, 2000, 480)]})
    (output_dir / "test-tom-high.mid").write_bytes(tom_high)

    tom_mid = create_midi_file("Tom Mid", {9: [(45, 90, tick) for tick in range(0, 2000, 480)]})
    (output_dir / "test-tom-mid.mid").write_bytes(tom_mid)

    tom_low = create_midi_file("Tom Low", {9: [(41, 90, tick) for tick in range(0, 2000, 480)]})
    (output_dir / "test-tom-low.mid").write_bytes(tom_low)

    # Test 4: Zero velocity notes (should be ignored)
    zero_velocity = create_midi_file("Zero Velocity", {9: [(35, 0, 0), (38, 100, 240)]})
    (output_dir / "test-zero-velocity.mid").write_bytes(zero_velocity)

    # Test 5: All hihat variations
    hihats = create_midi_file("Hi-hats", {
        9: [
            (42, 90, 0),       # Closed
            (44, 85, 240),     # Pedal (also closed)
            (46, 80, 480),     # Open
            (42, 88, 720),     # Closed again
        ]
    })
    (output_dir / "test-hihats.mid").write_bytes(hihats)

    # Test 6: Wrong channel (should be ignored - drums are channel 9)
    wrong_channel = create_midi_file("Wrong Channel", {
        0: [(60, 100, 0), (64, 100, 240)],  # Melody channel
        9: [(35, 100, 120), (38, 100, 360)],  # Only these should be captured
    })
    (output_dir / "test-wrong-channel.mid").write_bytes(wrong_channel)

    print(f"Generated test MIDI files in {output_dir}")


if __name__ == "__main__":
    output_dir = Path(__file__).parent.parent / "Tests" / "PipelineRuntimeTests" / "Fixtures" / "midi"
    generate_test_midis(output_dir)
