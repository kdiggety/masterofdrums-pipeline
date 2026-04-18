#!/usr/bin/env python3
import argparse
import json
import math
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

KICK = {
    "kick", "bd", "bass_drum", "bassdrum", "bass_drum_1", "bass_drum_2", "bassdrum_1", "bassdrum_2",
    "kik", "kick_drum", "kickdrum", "surdo"
}
SNARE = {
    "snare", "sd", "sn", "rimshot", "rim", "cross_stick", "side_stick", "sidestick", "snare_drum",
    "snaredrum", "rim_shot", "vibraslap", "claves", "castanets", "short_guiro", "guiro_short",
    "mute_cuica", "cuica_mute", "wood_block", "woodblock", "high_wood_block", "highwood_block"
}
HH_CLOSED = {
    "hihat_closed", "closed_hihat", "closed_hat", "closed_hi_hat", "hhc", "hat_closed", "hi_hat_closed",
    "chh", "hh", "hihat", "closed_hi_hat_edge", "tight_hihat", "tight_hi_hat", "pedal_hihat", "pedal_hi_hat",
    "cowbell", "shaker", "tambourine", "cabasa", "maracas", "short_whistle", "whistle_short",
    "high_agogo", "agogo_high", "sleigh_bells", "bell_tree", "mute_triangle", "triangle_mute"
}
HH_OPEN = {
    "hihat_open", "open_hihat", "open_hat", "open_hi_hat", "hho", "hat_open", "hi_hat_open", "ohh",
    "half_open_hihat", "half_open_hi_hat", "open_hi_hat_edge", "long_whistle", "whistle_long",
    "long_guiro", "guiro_long", "open_triangle", "triangle_open"
}
TOM_LOW = {
    "tom_low", "low_tom", "floor_tom", "floortom", "low_floor_tom", "floor_tom_1", "floor_tom_2", "tom_3",
    "low_bongo", "bongo_low", "low_conga", "conga_low", "low_timbale", "timbale_low", "low_wood_block",
    "lowwood_block", "woodblock_low", "lowwoodblock"
}
TOM_MID = {
    "tom_mid", "mid_tom", "middle_tom", "mid_tom_1", "mid_tom_2", "tom_medium", "medium_tom", "rack_tom_2",
    "tom_2", "low_mid_tom", "lowmid_tom", "hi_mid_tom", "himid_tom", "mid_tom_2", "low_agogo", "agogo_low",
    "open_cuica", "cuica_open"
}
TOM_HIGH = {
    "tom_high", "high_tom", "rack_tom", "racktom", "high_rack_tom", "rack_tom_1", "tom_1", "high_floor_tom",
    "high_bongo", "bongo_high", "mute_high_conga", "conga_mute_high", "open_high_conga", "conga_open_high",
    "high_conga", "conga_high", "high_timbale", "timbale_high"
}
CRASH = {
    "crash", "crash_cymbal", "crash_left", "crash_right", "crash_1", "crash_2", "china", "china_cymbal",
    "splash", "splash_cymbal", "chinese_cymbal"
}
RIDE = {"ride", "ride_cymbal", "ride_bell", "ride_1", "ride_2"}
CLAP = {"clap", "handclap", "hand_clap"}
PERC = {"percussion", "perc"}

MIDI_MAP = {
    # Kick
    35: "kick", 36: "kick",
    # Snare, Rimshot, Vibraslap, Clicks
    37: "snare", 38: "snare", 40: "snare", 39: "clap",
    # Hi-Hat
    42: "hihat_closed", 44: "hihat_closed", 46: "hihat_open",
    # Toms
    41: "tom_low", 43: "tom_low",
    45: "tom_mid",
    47: "tom_high", 48: "tom_high", 50: "tom_high",
    # Cymbals
    49: "crash", 52: "crash", 55: "crash", 57: "crash",
    51: "ride", 53: "ride", 59: "ride",
    # Percussion (high/mid/low mapped by pitch)
    54: "tom_high",    # Vibra Slap (high pitched)
    56: "tom_mid",     # Cowbell (mid-high)
    58: "hihat_closed", # Vibraphone (bright)
    60: "tom_high",    # High Bongo
    61: "tom_high",    # High Conga
    62: "tom_low",     # Low Conga
    63: "tom_high",    # High Timbale
    64: "tom_low",     # Low Timbale
    65: "hihat_closed", # Agogo (bright)
    66: "hihat_closed", # Cabasa
    67: "hihat_closed", # Maracas
    68: "snare",       # Claves (wooden click)
    69: "snare",       # Woodblock (click)
    70: "tom_mid",     # Cuica (muted)
    71: "tom_high",    # Triangle (muted)
    72: "crash",       # Metronome Bell
    73: "crash",       # Metronome Click
    74: "crash",       # Bell
    75: "hihat_closed", # Castanets
    76: "hihat_closed", # Surdo
    77: "hihat_closed", # Jingle Bell
    78: "percussion", 79: "percussion", 80: "percussion", 81: "percussion",
    82: "percussion", 83: "percussion",
}


def raw_string(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, (int, float, str)):
        return str(value)
    return None


def raw_int(value: Any) -> int | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float) and value.is_integer():
        return int(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            return None
    return None


def normalize_label(value: Any) -> str | None:
    raw = raw_string(value)
    if raw is None:
        return None
    lowered = raw.lower()
    chars = [c if c.isalnum() else "_" for c in lowered]
    collapsed = "".join(chars)
    while "__" in collapsed:
        collapsed = collapsed.replace("__", "_")
    collapsed = collapsed.strip("_")
    return collapsed or None


def flatten_label_value(value: Any) -> Any:
    if raw_string(value) is not None:
        return value
    if isinstance(value, dict):
        for key in ("label", "name", "id", "family", "instrument"):
            if key in value:
                return value[key]
    return None


def event_lane_value(candidate: dict[str, Any]) -> Any:
    for key in ("lane", "label", "sourceLabel", "source_label", "instrument", "class", "type", "name", "pitch"):
        if key in candidate:
            return flatten_label_value(candidate[key])
    for nested_key in ("instrument", "class", "lane", "source", "drum"):
        nested = candidate.get(nested_key)
        if isinstance(nested, dict):
            for key in ("label", "name", "id", "family", "instrument"):
                if key in nested:
                    return flatten_label_value(nested[key])
    return None


def map_lane(raw_value: Any) -> str | None:
    midi = raw_int(raw_value)
    if midi is not None and midi in MIDI_MAP:
        return MIDI_MAP[midi]
    raw = normalize_label(raw_value)
    if raw is None:
        return None
    if raw in KICK:
        return "kick"
    if raw in SNARE:
        return "snare"
    if raw in HH_CLOSED:
        return "hihat_closed"
    if raw in HH_OPEN:
        return "hihat_open"
    if raw in TOM_LOW:
        return "tom_low"
    if raw in TOM_MID:
        return "tom_mid"
    if raw in TOM_HIGH:
        return "tom_high"
    if raw in CRASH:
        return "crash"
    if raw in RIDE:
        return "ride"
    if raw in CLAP:
        return "clap"
    if raw in PERC:
        return "percussion"
    return None


def candidate_root_objects(raw: Any) -> list[dict[str, Any]]:
    if not isinstance(raw, dict):
        return []
    interesting = {
        "result", "output", "payload", "data", "analysis", "response", "prediction", "timing", "drums",
        "percussion", "tracks", "track", "events", "drumEvents", "drum_events", "drumEventCandidates",
        "drum_event_candidates", "candidates", "hits", "notes", "transcription", "detections"
    }
    ordered: list[dict[str, Any]] = []
    seen: set[tuple[str, ...]] = set()

    def append(obj: dict[str, Any]):
        key = tuple(sorted(obj.keys()))
        if key not in seen:
            seen.add(key)
            ordered.append(obj)

    def visit(value: Any, preferred: bool = False):
        if isinstance(value, dict):
            if preferred:
                append(value)
            for k, v in value.items():
                visit(v, preferred or k in interesting)
        elif isinstance(value, list):
            for item in value:
                visit(item, preferred)

    visit(raw, True)
    return ordered


def extract_event_objects(candidate: Any) -> list[dict[str, Any]]:
    if candidate is None:
        return []
    if isinstance(candidate, list):
        out: list[dict[str, Any]] = []
        for item in candidate:
            out.extend(extract_event_objects(item))
        return out
    if isinstance(candidate, dict):
        for wrapper in ("event", "hit", "drum"):
            nested = candidate.get(wrapper)
            if isinstance(nested, dict):
                merged = dict(candidate)
                merged.update(nested)
                return [merged]
        if event_lane_value(candidate) is not None:
            return [candidate]
        for key in ("items", "events", "hits", "notes", "candidates", "drumEvents", "drum_events", "tracks", "instruments", "predictions", "detections", "children"):
            nested = extract_event_objects(candidate.get(key))
            if nested:
                return nested
        for value in candidate.values():
            nested = extract_event_objects(value)
            if nested:
                return nested
    return []


def extract_raw_candidates(raw: Any) -> list[dict[str, Any]]:
    for root in candidate_root_objects(raw):
        arrays = [
            root.get("drumEvents"), root.get("drum_events"), root.get("drumEventCandidates"), root.get("drum_event_candidates"),
            root.get("events"), root.get("hits"), root.get("notes"), root.get("candidates"),
            (root.get("drums") or {}).get("events") if isinstance(root.get("drums"), dict) else None,
            (root.get("drums") or {}).get("hits") if isinstance(root.get("drums"), dict) else None,
            (root.get("percussion") or {}).get("events") if isinstance(root.get("percussion"), dict) else None,
            (root.get("timing") or {}).get("events") if isinstance(root.get("timing"), dict) else None,
            root.get("tracks"), root.get("instruments"), root.get("predictions"), root.get("detections"),
            (root.get("transcription") or {}).get("events") if isinstance(root.get("transcription"), dict) else None,
        ]
        for candidate in arrays:
            values = extract_event_objects(candidate)
            if values:
                return values
    return []


def summarize(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text())
    raw = payload.get("rawAnalyzerOutput", payload)
    candidates = extract_raw_candidates(raw)
    label_counter = Counter()
    mapped_counter = Counter()
    unmapped_counter = Counter()
    family_counter = Counter()

    for candidate in candidates:
        raw_label = event_lane_value(candidate)
        normalized = normalize_label(raw_label) or "<missing>"
        mapped = map_lane(raw_label)
        label_counter[normalized] += 1
        if mapped is None:
            unmapped_counter[normalized] += 1
        else:
            mapped_counter[mapped] += 1
            family_counter[mapped.split("_")[0]] += 1

    normalized_events = payload.get("drumEvents") if isinstance(payload.get("drumEvents"), list) else None
    normalized_counts = Counter()
    if normalized_events is not None:
        for event in normalized_events:
            lane = event.get("lane")
            if lane:
                normalized_counts[lane] += 1

    notes = (((payload.get("chart") or {}) if isinstance(payload.get("chart"), dict) else {}).get("notes")
             if isinstance(payload.get("chart"), dict) else None)
    chart_counts = Counter()
    if isinstance(notes, list):
        for note in notes:
            lane = note.get("lane")
            if lane:
                chart_counts[lane] += 1

    diagnostics = payload.get("drumEventDiagnostics") or {}
    return {
        "path": str(path),
        "rawCandidateCount": len(candidates),
        "rawLabels": label_counter,
        "mappedLaneCandidates": mapped_counter,
        "unmappedLabels": unmapped_counter,
        "normalizedDrumEvents": normalized_counts,
        "baseChartNotes": chart_counts,
        "diagnostics": diagnostics,
    }


def print_counter(title: str, counter: Counter):
    print(f"\n{title}")
    if not counter:
        print("  (none)")
        return
    for key, value in sorted(counter.items(), key=lambda item: (-item[1], item[0])):
        print(f"  {key}: {value}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit analyzer label/lane mapping from analysis, normalized-analysis, or base-chart JSON artifacts.")
    parser.add_argument("artifacts", nargs="+", help="JSON artifact path(s) to inspect")
    args = parser.parse_args()

    aggregate_raw_labels = Counter()
    aggregate_mapped = Counter()
    aggregate_unmapped = Counter()
    aggregate_normalized = Counter()
    aggregate_chart = Counter()
    aggregate_diag = Counter()

    for artifact in args.artifacts:
        summary = summarize(Path(artifact))
        print(f"== {summary['path']} ==")
        print(f"raw candidates: {summary['rawCandidateCount']}")
        diag = summary["diagnostics"]
        if diag:
            print("diagnostics:")
            for key in (
                "rawCandidateCount", "mappedCandidateCount", "postShapingEventCount", "usedFallback",
                "droppedMissingOnsetCount", "droppedUnknownLaneCount", "deduplicatedCandidateCount", "shapingReductionCount"
            ):
                if key in diag:
                    print(f"  {key}: {diag[key]}")
                    if isinstance(diag[key], int):
                        aggregate_diag[key] += diag[key]
        print_counter("raw labels", summary["rawLabels"])
        print_counter("mapped lane candidates", summary["mappedLaneCandidates"])
        print_counter("unmapped labels", summary["unmappedLabels"])
        print_counter("normalized drum events", summary["normalizedDrumEvents"])
        print_counter("base chart notes", summary["baseChartNotes"])
        aggregate_raw_labels.update(summary["rawLabels"])
        aggregate_mapped.update(summary["mappedLaneCandidates"])
        aggregate_unmapped.update(summary["unmappedLabels"])
        aggregate_normalized.update(summary["normalizedDrumEvents"])
        aggregate_chart.update(summary["baseChartNotes"])
        print()

    if len(args.artifacts) > 1:
        print("== aggregate ==")
        print_counter("raw labels", aggregate_raw_labels)
        print_counter("mapped lane candidates", aggregate_mapped)
        print_counter("unmapped labels", aggregate_unmapped)
        print_counter("normalized drum events", aggregate_normalized)
        print_counter("base chart notes", aggregate_chart)
        if aggregate_diag:
            print("\ndiagnostics totals")
            for key, value in sorted(aggregate_diag.items()):
                print(f"  {key}: {value}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
