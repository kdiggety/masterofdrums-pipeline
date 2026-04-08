#!/usr/bin/env python3
"""Summarize a MasterOfDrums chart JSON artifact.

Supports both the app's legacy chart JSON shape and the pipeline base-chart shape.
Prints a compact JSON summary for quick debugging.
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any


def usage() -> int:
    print("usage: python3 scripts/chart-summary.py path/to/chart.json", file=sys.stderr)
    return 2


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload, dict):
        raise ValueError("chart JSON root must be an object")
    return payload


def extract_notes(payload: dict[str, Any]) -> list[dict[str, Any]]:
    chart = payload.get("chart")
    if isinstance(chart, dict) and isinstance(chart.get("notes"), list):
        return [item for item in chart["notes"] if isinstance(item, dict)]
    if isinstance(payload.get("notes"), list):
        return [item for item in payload["notes"] if isinstance(item, dict)]
    return []


def note_time(note: dict[str, Any]) -> Any:
    for key in ("startSeconds", "time", "onsetSeconds"):
        if key in note:
            return note[key]
    return None


def summarize(path: Path) -> dict[str, Any]:
    payload = load_json(path)
    notes = extract_notes(payload)
    lanes = [note.get("lane") for note in notes if isinstance(note.get("lane"), str)]
    lane_counts = dict(sorted(Counter(lanes).items(), key=lambda item: item[0]))
    top_level_keys = sorted(payload.keys())

    chart = payload.get("chart") if isinstance(payload.get("chart"), dict) else None
    chart_keys = sorted(chart.keys()) if chart else None
    source = payload.get("source") if isinstance(payload.get("source"), dict) else None
    timing = payload.get("timing") if isinstance(payload.get("timing"), dict) else None

    sample_notes = []
    for note in notes[:5]:
        sample_notes.append(
            {
                "noteID": note.get("noteID", note.get("id")),
                "lane": note.get("lane"),
                "time": note_time(note),
                "rawKeys": sorted(note.keys()),
            }
        )

    return {
        "path": str(path),
        "topLevelKeys": top_level_keys,
        "chartKeys": chart_keys,
        "title": payload.get("title") or (source or {}).get("title"),
        "noteCount": len(notes),
        "uniqueLanes": sorted(lane_counts.keys()),
        "laneCounts": lane_counts,
        "timing": timing,
        "sourceKeys": sorted(source.keys()) if source else None,
        "sampleNotes": sample_notes,
    }


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        return usage()

    path = Path(argv[1]).expanduser().resolve()
    if not path.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        return 1

    try:
        summary = summarize(path)
    except Exception as exc:  # pragma: no cover - CLI error path
        print(f"error: {exc}", file=sys.stderr)
        return 1

    json.dump(summary, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
