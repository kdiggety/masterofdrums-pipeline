#!/usr/bin/env python3
"""Run the same source through primary and fallback timing paths, then summarize deltas.

This is meant for rollout/debugging work around scripts/analyzer-wrapper.py. It makes the
comparison repeatable by:
- invoking the wrapper once in primary-only mode
- invoking the wrapper once in forced-fallback mode
- capturing both raw payloads
- emitting a compact machine-readable + human-readable delta summary

Typical usage:

  ./.venv/bin/python ./scripts/compare-timing-paths.py \
    --input /path/to/song.wav \
    --output-dir ./tmp/compare-song

The script resolves commands from the same environment variables the wrapper already uses,
so it can be dropped into the current rollout workflow without extra wiring.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import pathlib
import shlex
import subprocess
import sys
from typing import Any

DEFAULT_PRIMARY_ENV = "PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND"
DEFAULT_FALLBACK_ENV = "PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND"
DEFAULT_LEGACY_ENV = "PIPELINE_ANALYZER_BACKEND_COMMAND"
DEFAULT_WRAPPER = "scripts/analyzer-wrapper.py"
EVENT_ONSET_TOLERANCE_SECONDS = 0.05


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Compare primary vs fallback timing outputs")
    parser.add_argument("--input", required=True, help="input audio path")
    parser.add_argument("--output-dir", required=True, help="directory for raw outputs + summaries")
    parser.add_argument("--wrapper", default=DEFAULT_WRAPPER, help=f"wrapper entry point (default: {DEFAULT_WRAPPER})")
    parser.add_argument("--python", default=sys.executable, help="Python interpreter to use for wrapper/backend invocations")
    parser.add_argument("--primary-backend-command", help="primary backend shell command; may contain {input}/{output}")
    parser.add_argument("--fallback-backend-command", help="fallback backend shell command; may contain {input}/{output}")
    parser.add_argument("--primary-backend-env", default=DEFAULT_PRIMARY_ENV)
    parser.add_argument("--fallback-backend-env", default=DEFAULT_FALLBACK_ENV)
    parser.add_argument("--legacy-backend-env", default=DEFAULT_LEGACY_ENV)
    parser.add_argument("--validation-mode", default=os.environ.get("PIPELINE_ANALYZER_VALIDATION_MODE", "require-timing"))
    parser.add_argument("--backend-stdout-json", action="store_true", help="forward --backend-stdout-json to wrapper")
    parser.add_argument("--requested-by", default="compare-timing-paths")
    parser.add_argument("--source-type", default="file")
    parser.add_argument("--json-only", action="store_true", help="print only the machine-readable summary JSON")
    return parser


def load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object at {path}")
    return value


def safe_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if math.isfinite(parsed):
        return parsed
    return None


def safe_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def pick_command(explicit: str | None, primary_env: str, legacy_env: str) -> str | None:
    if explicit:
        return explicit
    return os.environ.get(primary_env) or os.environ.get(legacy_env)


def pick_fallback_command(explicit: str | None, fallback_env: str) -> str | None:
    if explicit:
        return explicit
    return os.environ.get(fallback_env)


def run_wrapper(*, python: str, wrapper: str, input_path: str, output_path: str, primary_command: str, fallback_command: str | None, fallback_policy: str, validation_mode: str, source_type: str, requested_by: str, backend_stdout_json: bool) -> tuple[list[str], pathlib.Path]:
    command = [
        python,
        wrapper,
        "--input",
        input_path,
        "--output",
        output_path,
        "--primary-backend-command",
        primary_command,
        "--fallback-policy",
        fallback_policy,
        "--validation-mode",
        validation_mode,
    ]
    if fallback_command:
        command.extend(["--fallback-backend-command", fallback_command])
    if backend_stdout_json:
        command.append("--backend-stdout-json")

    env = os.environ.copy()
    env.setdefault("PIPELINE_ANALYZER_SOURCE_TYPE", source_type)
    env.setdefault("PIPELINE_ANALYZER_SOURCE_URI", pathlib.Path(input_path).resolve().as_uri())
    env.setdefault("PIPELINE_ANALYZER_REQUESTED_BY", requested_by)
    env["PIPELINE_ANALYZER_INPUT_PATH"] = input_path
    env["PIPELINE_ANALYZER_OUTPUT_PATH"] = output_path

    result = subprocess.run(command, capture_output=True, text=True, check=False, env=env)
    log_lines = [
        f"$ {' '.join(shlex.quote(part) for part in command)}",
        f"exit_code={result.returncode}",
    ]
    if result.stdout.strip():
        log_lines.extend(["[stdout]", result.stdout.rstrip()])
    if result.stderr.strip():
        log_lines.extend(["[stderr]", result.stderr.rstrip()])
    if result.returncode != 0:
        raise RuntimeError("wrapper invocation failed:\n" + "\n".join(log_lines))
    return log_lines, pathlib.Path(output_path)


TIMING_KEYS = (
    "beats",
    "beatTimes",
    "beat_times",
)
DOWNBEAT_KEYS = (
    "downbeats",
    "downbeatTimes",
    "downbeat_times",
)
EVENT_KEYS = (
    "drumEvents",
    "drum_events",
    "events",
    "hits",
    "notes",
    "candidates",
    "predictions",
    "detections",
)


CONFIDENCE_BUCKETS: tuple[tuple[str, float, float], ...] = (
    ("unknown", float("-inf"), float("-inf")),
    ("low", 0.0, 0.5),
    ("medium", 0.5, 0.8),
    ("high", 0.8, 1.01),
)


def first_list(payload: dict[str, Any], *keys: str) -> list[Any]:
    for key in keys:
        value = payload.get(key)
        if isinstance(value, list):
            return value
    return []


def nested_dict(payload: dict[str, Any], key: str) -> dict[str, Any]:
    value = payload.get(key)
    return value if isinstance(value, dict) else {}


def extract_times(payload: dict[str, Any], keys: tuple[str, ...]) -> list[float]:
    candidates = []
    root_values = first_list(payload, *keys)
    timing_values = first_list(nested_dict(payload, "timing"), *keys)
    candidates.extend(root_values)
    candidates.extend(timing_values)

    result: list[float] = []
    for item in candidates:
        if isinstance(item, dict):
            for subkey in ("seconds", "time", "start", "offset", "position"):
                value = safe_float(item.get(subkey))
                if value is not None:
                    result.append(round(value, 6))
                    break
        else:
            value = safe_float(item)
            if value is not None:
                result.append(round(value, 6))
    deduped: list[float] = []
    for value in sorted(result):
        if deduped and abs(deduped[-1] - value) <= 0.0005:
            continue
        deduped.append(value)
    return deduped


def extract_segments(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw = payload.get("segments")
    if not isinstance(raw, list):
        return []
    result: list[dict[str, Any]] = []
    for index, item in enumerate(raw):
        if not isinstance(item, dict):
            continue
        result.append({
            "index": safe_int(item.get("index")) if safe_int(item.get("index")) is not None else index,
            "startSeconds": safe_float(item.get("startSeconds", item.get("start_seconds", item.get("start")))),
            "endSeconds": safe_float(item.get("endSeconds", item.get("end_seconds", item.get("end")))),
            "label": item.get("label") if isinstance(item.get("label"), str) else None,
        })
    return result


def extract_events(payload: dict[str, Any]) -> list[dict[str, Any]]:
    candidates: list[Any] = []
    candidates.extend(first_list(payload, *EVENT_KEYS))
    timing = nested_dict(payload, "timing")
    analysis = nested_dict(payload, "analysis")
    candidates.extend(first_list(timing, *EVENT_KEYS))
    candidates.extend(first_list(analysis, *EVENT_KEYS))

    result: list[dict[str, Any]] = []
    for index, item in enumerate(candidates):
        if not isinstance(item, dict):
            continue
        onset = safe_float(
            item.get("onsetSeconds", item.get("onset_seconds", item.get("seconds", item.get("time", item.get("start")))))
        )
        lane_value = item.get("lane", item.get("instrument", item.get("type", item.get("class"))))
        lane = str(lane_value).strip() if lane_value is not None and str(lane_value).strip() else "unknown"
        source_value = item.get("sourceLabel", item.get("source", item.get("origin", item.get("backend"))))
        source = str(source_value).strip() if source_value is not None and str(source_value).strip() else "unknown"
        confidence = safe_float(item.get("confidence", item.get("score", item.get("probability"))))
        event_id_value = item.get("eventID", item.get("eventId", item.get("id")))
        result.append({
            "index": index,
            "eventID": str(event_id_value) if event_id_value is not None else None,
            "onsetSeconds": round(onset, 6) if onset is not None else None,
            "lane": lane,
            "label": str(item.get("label")) if item.get("label") is not None else None,
            "confidence": round(confidence, 4) if confidence is not None else None,
            "source": source,
        })
    result.sort(key=lambda item: (item["onsetSeconds"] is None, item["onsetSeconds"] if item["onsetSeconds"] is not None else float("inf"), item["lane"], item["index"]))
    return result


def bucket_confidence(value: float | None) -> str:
    if value is None:
        return "unknown"
    for name, lower, upper in CONFIDENCE_BUCKETS[1:]:
        if lower <= value < upper:
            return name
    return "high"


def tally_strings(values: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for value in values:
        counts[value] = counts.get(value, 0) + 1
    return {key: counts[key] for key in sorted(counts)}


def summarize_payload(payload: dict[str, Any]) -> dict[str, Any]:
    analysis = nested_dict(payload, "analysis")
    runtime = nested_dict(payload, "runtime")
    beats = extract_times(payload, TIMING_KEYS)
    downbeats = extract_times(payload, DOWNBEAT_KEYS)
    segments = extract_segments(payload)
    events = extract_events(payload)
    provenance = {
        "backend": runtime.get("backend"),
        "selectedBackend": runtime.get("selectedBackend"),
        "backendCommand": runtime.get("backendCommand"),
        "primaryBackend": runtime.get("primaryBackend"),
        "primaryBackendCommand": runtime.get("primaryBackendCommand"),
        "fallbackBackendCommand": runtime.get("fallbackBackendCommand"),
        "fallbackUsed": runtime.get("fallbackUsed"),
        "fallbackReason": runtime.get("fallbackReason"),
        "mode": runtime.get("mode"),
        "model": runtime.get("model"),
        "eventBackendUsed": runtime.get("eventBackendUsed"),
        "eventBackendCommand": runtime.get("eventBackendCommand"),
    }
    beat_intervals = [round(b - a, 6) for a, b in zip(beats, beats[1:]) if b > a]
    lane_counts = tally_strings([event["lane"] for event in events])
    source_counts = tally_strings([event["source"] for event in events])
    confidence_counts = tally_strings([bucket_confidence(event["confidence"]) for event in events])
    return {
        "tempoBPM": safe_float(analysis.get("estimatedTempoBPM", analysis.get("tempoBPM"))),
        "downbeatOffsetSeconds": safe_float(analysis.get("downbeatOffsetSeconds", analysis.get("downbeat_offset_seconds"))),
        "analysisConfidence": safe_float(analysis.get("confidence")),
        "beatCount": len(beats),
        "beatStarts": beats,
        "beatIntervals": beat_intervals,
        "downbeatCount": len(downbeats),
        "downbeatStarts": downbeats,
        "segmentCount": len(segments),
        "segmentBoundaries": [
            {
                "index": segment["index"],
                "startSeconds": round(segment["startSeconds"], 6) if segment["startSeconds"] is not None else None,
                "endSeconds": round(segment["endSeconds"], 6) if segment["endSeconds"] is not None else None,
                "label": segment["label"],
            }
            for segment in segments
        ],
        "eventCount": len(events),
        "eventLaneCounts": lane_counts,
        "eventSourceCounts": source_counts,
        "eventConfidenceCounts": confidence_counts,
        "eventOnsets": [event["onsetSeconds"] for event in events if event["onsetSeconds"] is not None],
        "eventsPreview": events[:12],
        "warnings": payload.get("warnings") if isinstance(payload.get("warnings"), list) else [],
        "provenance": provenance,
    }


def compare_lists(left: list[Any], right: list[Any], *, tolerance: float = 0.0005) -> dict[str, Any]:
    max_count = max(len(left), len(right))
    mismatches: list[dict[str, Any]] = []
    for index in range(max_count):
        lhs = left[index] if index < len(left) else None
        rhs = right[index] if index < len(right) else None
        if isinstance(lhs, (int, float)) and isinstance(rhs, (int, float)):
            delta = float(rhs) - float(lhs)
            if abs(delta) > tolerance:
                mismatches.append({"index": index, "primary": round(float(lhs), 6), "fallback": round(float(rhs), 6), "delta": round(delta, 6)})
        elif lhs != rhs:
            mismatches.append({"index": index, "primary": lhs, "fallback": rhs})
    return {
        "countDelta": len(right) - len(left),
        "mismatchCount": len(mismatches),
        "mismatchesPreview": mismatches[:12],
    }


def compare_count_maps(left: dict[str, int], right: dict[str, int]) -> dict[str, Any]:
    keys = sorted(set(left) | set(right))
    differences = []
    for key in keys:
        lhs = left.get(key, 0)
        rhs = right.get(key, 0)
        if lhs != rhs:
            differences.append({"key": key, "primary": lhs, "fallback": rhs, "delta": rhs - lhs})
    return {
        "primaryTotal": sum(left.values()),
        "fallbackTotal": sum(right.values()),
        "differenceCount": len(differences),
        "differencesPreview": differences[:12],
    }


def compare_event_onsets(left: list[float], right: list[float], *, tolerance: float = EVENT_ONSET_TOLERANCE_SECONDS) -> dict[str, Any]:
    matched_right: set[int] = set()
    matches: list[dict[str, Any]] = []
    primary_only: list[dict[str, Any]] = []

    for left_index, left_onset in enumerate(left):
        best_index = None
        best_delta = None
        for right_index, right_onset in enumerate(right):
            if right_index in matched_right:
                continue
            delta = right_onset - left_onset
            if abs(delta) > tolerance:
                continue
            if best_delta is None or abs(delta) < abs(best_delta):
                best_index = right_index
                best_delta = delta
        if best_index is None:
            primary_only.append({"index": left_index, "onsetSeconds": left_onset})
            continue
        matched_right.add(best_index)
        matches.append({
            "primaryIndex": left_index,
            "fallbackIndex": best_index,
            "primaryOnsetSeconds": left_onset,
            "fallbackOnsetSeconds": right[best_index],
            "delta": round(best_delta or 0.0, 6),
        })

    fallback_only = [
        {"index": right_index, "onsetSeconds": right_onset}
        for right_index, right_onset in enumerate(right)
        if right_index not in matched_right
    ]
    mismatched_matches = [item for item in matches if abs(item["delta"]) > 0.0005]
    return {
        "toleranceSeconds": tolerance,
        "matchCount": len(matches),
        "matchedButShiftedCount": len(mismatched_matches),
        "primaryOnlyCount": len(primary_only),
        "fallbackOnlyCount": len(fallback_only),
        "shiftedPreview": mismatched_matches[:12],
        "primaryOnlyPreview": primary_only[:12],
        "fallbackOnlyPreview": fallback_only[:12],
    }


PROVENANCE_KEYS = (
    "backend",
    "selectedBackend",
    "backendCommand",
    "primaryBackend",
    "primaryBackendCommand",
    "fallbackBackendCommand",
    "fallbackUsed",
    "fallbackReason",
    "mode",
    "model",
    "eventBackendUsed",
    "eventBackendCommand",
)


def build_delta(primary: dict[str, Any], fallback: dict[str, Any]) -> dict[str, Any]:
    provenance_delta: dict[str, Any] = {}
    for key in PROVENANCE_KEYS:
        lhs = primary["provenance"].get(key)
        rhs = fallback["provenance"].get(key)
        if lhs != rhs:
            provenance_delta[key] = {"primary": lhs, "fallback": rhs}

    return {
        "tempoBPM": {
            "primary": primary["tempoBPM"],
            "fallback": fallback["tempoBPM"],
            "delta": round((fallback["tempoBPM"] or 0) - (primary["tempoBPM"] or 0), 6) if primary["tempoBPM"] is not None and fallback["tempoBPM"] is not None else None,
        },
        "downbeatOffsetSeconds": {
            "primary": primary["downbeatOffsetSeconds"],
            "fallback": fallback["downbeatOffsetSeconds"],
            "delta": round((fallback["downbeatOffsetSeconds"] or 0) - (primary["downbeatOffsetSeconds"] or 0), 6) if primary["downbeatOffsetSeconds"] is not None and fallback["downbeatOffsetSeconds"] is not None else None,
        },
        "analysisConfidence": {
            "primary": primary["analysisConfidence"],
            "fallback": fallback["analysisConfidence"],
            "delta": round((fallback["analysisConfidence"] or 0) - (primary["analysisConfidence"] or 0), 6) if primary["analysisConfidence"] is not None and fallback["analysisConfidence"] is not None else None,
        },
        "beatGrid": {
            "primaryBeatCount": primary["beatCount"],
            "fallbackBeatCount": fallback["beatCount"],
            "beatStarts": compare_lists(primary["beatStarts"], fallback["beatStarts"]),
            "beatIntervals": compare_lists(primary["beatIntervals"], fallback["beatIntervals"]),
            "downbeatStarts": compare_lists(primary["downbeatStarts"], fallback["downbeatStarts"]),
        },
        "segments": {
            "primarySegmentCount": primary["segmentCount"],
            "fallbackSegmentCount": fallback["segmentCount"],
            "boundaries": compare_lists(primary["segmentBoundaries"], fallback["segmentBoundaries"]),
        },
        "events": {
            "primaryEventCount": primary["eventCount"],
            "fallbackEventCount": fallback["eventCount"],
            "countDelta": fallback["eventCount"] - primary["eventCount"],
            "laneCounts": compare_count_maps(primary["eventLaneCounts"], fallback["eventLaneCounts"]),
            "sourceCounts": compare_count_maps(primary["eventSourceCounts"], fallback["eventSourceCounts"]),
            "confidenceCounts": compare_count_maps(primary["eventConfidenceCounts"], fallback["eventConfidenceCounts"]),
            "onsets": compare_event_onsets(primary["eventOnsets"], fallback["eventOnsets"]),
        },
        "provenance": provenance_delta,
    }


def render_text(summary: dict[str, Any]) -> str:
    primary = summary["primary"]
    fallback = summary["fallback"]
    delta = summary["delta"]
    lines = [
        "[pipeline] timing path comparison",
        f"input: {summary['inputPath']}",
        f"output_dir: {summary['outputDir']}",
        "",
        "primary:",
        f"  tempo_bpm={primary['tempoBPM']} downbeat_offset={primary['downbeatOffsetSeconds']} beat_count={primary['beatCount']} segment_count={primary['segmentCount']} event_count={primary['eventCount']} analysis_confidence={primary['analysisConfidence']}",
        f"  backend={primary['provenance'].get('backend')} selected={primary['provenance'].get('selectedBackend')} fallback_used={primary['provenance'].get('fallbackUsed')}",
        f"  lane_mix={json.dumps(primary['eventLaneCounts'], sort_keys=True)}",
        f"  confidence_mix={json.dumps(primary['eventConfidenceCounts'], sort_keys=True)} source_mix={json.dumps(primary['eventSourceCounts'], sort_keys=True)}",
        "fallback:",
        f"  tempo_bpm={fallback['tempoBPM']} downbeat_offset={fallback['downbeatOffsetSeconds']} beat_count={fallback['beatCount']} segment_count={fallback['segmentCount']} event_count={fallback['eventCount']} analysis_confidence={fallback['analysisConfidence']}",
        f"  backend={fallback['provenance'].get('backend')} selected={fallback['provenance'].get('selectedBackend')} fallback_used={fallback['provenance'].get('fallbackUsed')}",
        f"  lane_mix={json.dumps(fallback['eventLaneCounts'], sort_keys=True)}",
        f"  confidence_mix={json.dumps(fallback['eventConfidenceCounts'], sort_keys=True)} source_mix={json.dumps(fallback['eventSourceCounts'], sort_keys=True)}",
        "",
        "deltas:",
        f"  tempo_bpm_delta={delta['tempoBPM']['delta']}",
        f"  downbeat_offset_delta={delta['downbeatOffsetSeconds']['delta']}",
        f"  analysis_confidence_delta={delta['analysisConfidence']['delta']}",
        f"  beat_count_delta={delta['beatGrid']['beatStarts']['countDelta']} beat_start_mismatches={delta['beatGrid']['beatStarts']['mismatchCount']} beat_interval_mismatches={delta['beatGrid']['beatIntervals']['mismatchCount']}",
        f"  downbeat_count_delta={delta['beatGrid']['downbeatStarts']['countDelta']} downbeat_mismatches={delta['beatGrid']['downbeatStarts']['mismatchCount']}",
        f"  segment_count_delta={delta['segments']['boundaries']['countDelta']} segment_boundary_mismatches={delta['segments']['boundaries']['mismatchCount']}",
        f"  event_count_delta={delta['events']['countDelta']} lane_mix_differences={delta['events']['laneCounts']['differenceCount']} confidence_mix_differences={delta['events']['confidenceCounts']['differenceCount']} source_mix_differences={delta['events']['sourceCounts']['differenceCount']}",
        f"  event_onset_matches={delta['events']['onsets']['matchCount']} shifted_matches={delta['events']['onsets']['matchedButShiftedCount']} primary_only_onsets={delta['events']['onsets']['primaryOnlyCount']} fallback_only_onsets={delta['events']['onsets']['fallbackOnlyCount']}",
    ]
    if delta["provenance"]:
        lines.append("  provenance_differences:")
        for key, value in delta["provenance"].items():
            lines.append(f"    - {key}: primary={value['primary']!r} fallback={value['fallback']!r}")
    else:
        lines.append("  provenance_differences: none")

    preview_sections = [
        ("beat_start_mismatch_preview", delta["beatGrid"]["beatStarts"]["mismatchesPreview"]),
        ("downbeat_mismatch_preview", delta["beatGrid"]["downbeatStarts"]["mismatchesPreview"]),
        ("segment_boundary_mismatch_preview", delta["segments"]["boundaries"]["mismatchesPreview"]),
        ("event_lane_difference_preview", delta["events"]["laneCounts"]["differencesPreview"]),
        ("event_confidence_difference_preview", delta["events"]["confidenceCounts"]["differencesPreview"]),
        ("event_source_difference_preview", delta["events"]["sourceCounts"]["differencesPreview"]),
        ("event_shifted_preview", delta["events"]["onsets"]["shiftedPreview"]),
        ("event_primary_only_preview", delta["events"]["onsets"]["primaryOnlyPreview"]),
        ("event_fallback_only_preview", delta["events"]["onsets"]["fallbackOnlyPreview"]),
    ]
    for label, items in preview_sections:
        if items:
            lines.append(f"  {label}:")
            for item in items:
                lines.append(f"    - {json.dumps(item, sort_keys=True)}")
    return "\n".join(lines)


def main() -> int:
    args = build_parser().parse_args()
    input_path = str(pathlib.Path(args.input).resolve())
    output_dir = pathlib.Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    primary_command = pick_command(args.primary_backend_command, args.primary_backend_env, args.legacy_backend_env)
    fallback_command = pick_fallback_command(args.fallback_backend_command, args.fallback_backend_env)

    if not primary_command:
        raise SystemExit("no primary backend command configured; pass --primary-backend-command or set PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND / PIPELINE_ANALYZER_BACKEND_COMMAND")
    if not fallback_command:
        raise SystemExit("no fallback backend command configured; pass --fallback-backend-command or set PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND")

    wrapper_path = str(pathlib.Path(args.wrapper).resolve())
    primary_output = output_dir / "primary-output.json"
    fallback_output = output_dir / "fallback-output.json"

    primary_log, primary_path = run_wrapper(
        python=args.python,
        wrapper=wrapper_path,
        input_path=input_path,
        output_path=str(primary_output),
        primary_command=primary_command,
        fallback_command=fallback_command,
        fallback_policy="disabled",
        validation_mode=args.validation_mode,
        source_type=args.source_type,
        requested_by=args.requested_by,
        backend_stdout_json=args.backend_stdout_json,
    )
    fallback_log, fallback_path = run_wrapper(
        python=args.python,
        wrapper=wrapper_path,
        input_path=input_path,
        output_path=str(fallback_output),
        primary_command=primary_command,
        fallback_command=fallback_command,
        fallback_policy="always",
        validation_mode=args.validation_mode,
        source_type=args.source_type,
        requested_by=args.requested_by,
        backend_stdout_json=args.backend_stdout_json,
    )

    (output_dir / "primary-run.log").write_text("\n".join(primary_log) + "\n", encoding="utf-8")
    (output_dir / "fallback-run.log").write_text("\n".join(fallback_log) + "\n", encoding="utf-8")

    primary_payload = load_json(primary_path)
    fallback_payload = load_json(fallback_path)
    primary_summary = summarize_payload(primary_payload)
    fallback_summary = summarize_payload(fallback_payload)

    summary = {
        "inputPath": input_path,
        "outputDir": str(output_dir),
        "primaryOutputPath": str(primary_path),
        "fallbackOutputPath": str(fallback_path),
        "primary": primary_summary,
        "fallback": fallback_summary,
        "delta": build_delta(primary_summary, fallback_summary),
    }
    summary_json = json.dumps(summary, indent=2, sort_keys=True)
    summary_text = render_text(summary)

    (output_dir / "comparison-summary.json").write_text(summary_json + "\n", encoding="utf-8")
    (output_dir / "comparison-summary.txt").write_text(summary_text + "\n", encoding="utf-8")

    if args.json_only:
        print(summary_json)
    else:
        print(summary_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
