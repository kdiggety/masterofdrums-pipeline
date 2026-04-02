#!/usr/bin/env python3
"""Lightweight adapter for ADTOF-style drum-event outputs.

This is a research spike, not a full model integration.
It converts a few practical input shapes into the loose analyzer JSON the Swift runtime already understands.

Supported input JSON examples:
- {"hits": [{"time": 0.10, "pitch": 35, "velocity": 0.9}, ...]}
- {"events": [{"onset": 0.10, "midi": 38, "confidence": 0.8}, ...]}
- {"notes": [{"start": 0.10, "class": 42, "velocity": 127}, ...]}

The adapter leaves beat/downbeat generation to the primary analyzer path.
That keeps the ADTOF experiment focused on lane-level event feasibility instead of pretending it solves timing too.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any

MIDI_TO_LABEL = {
    35: "kick",
    36: "kick",
    38: "snare",
    39: "clap",
    42: "closed hi hat",
    44: "closed hi hat",
    46: "open hi hat",
    41: "floor tom",
    43: "floor tom",
    45: "mid tom",
    47: "high tom",
    48: "high tom",
    49: "crash",
    51: "ride",
    53: "ride",
    57: "crash",
    59: "ride",
    60: "percussion",
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Convert ADTOF-style event output into pipeline-friendly loose JSON")
    parser.add_argument("--input-json", required=True, help="input event JSON path")
    parser.add_argument("--output", required=True, help="output JSON path")
    parser.add_argument("--confidence-default", type=float, default=0.5)
    return parser


def first_list(payload: dict[str, Any], *keys: str) -> list[Any]:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, list):
            return value
    return []


def first_value(item: dict[str, Any], *keys: str) -> Any:
    for key in keys:
        if key in item:
            return item[key]
    return None


def maybe_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except Exception:
        return None
    return parsed


def normalize_velocity(value: Any) -> float | None:
    numeric = maybe_float(value)
    if numeric is None:
        return None
    if numeric > 1.0:
        numeric /= 127.0
    return min(max(numeric, 0.0), 1.0)


def normalize_event(index: int, item: dict[str, Any], confidence_default: float) -> dict[str, Any] | None:
    onset = maybe_float(first_value(item, "onsetSeconds", "onset", "time", "start", "start_seconds"))
    if onset is None:
        return None
    midi = first_value(item, "pitch", "midi", "class", "instrument")
    label = MIDI_TO_LABEL.get(int(midi)) if isinstance(midi, (int, float)) else first_value(item, "label", "name", "instrument")
    if label is None:
        label = str(midi) if midi is not None else "unknown"
    return {
        "eventID": first_value(item, "eventID", "event_id", "id") or f"adtof-{index}",
        "onsetSeconds": onset,
        "label": label,
        "velocity": normalize_velocity(first_value(item, "velocity", "amplitude", "strength")),
        "confidence": maybe_float(first_value(item, "confidence", "probability", "score")) or confidence_default,
        "sourceLabel": f"adtof_midi_{midi}" if midi is not None else "adtof_unknown",
    }


def main() -> int:
    args = build_parser().parse_args()
    payload = json.loads(pathlib.Path(args.input_json).read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise SystemExit("input JSON must be an object")
    raw_events = first_list(payload, "hits", "events", "notes")
    drum_events = []
    for index, item in enumerate(raw_events):
        if isinstance(item, dict):
            normalized = normalize_event(index, item, args.confidence_default)
            if normalized:
                drum_events.append(normalized)

    result = {
        "analysis": {
            "audioTrackCount": 1,
            "estimatedSegmentCount": 1,
            "confidence": args.confidence_default if drum_events else 0.0,
        },
        "drumEvents": drum_events,
        "warnings": [
            "ADTOF adapter emitted drum-event candidates only; pair with a primary beat/downbeat analyzer for chart timing"
        ],
        "note": "ADTOF research adapter converted event output into the pipeline's loose analyzer shape",
    }

    output_path = pathlib.Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
