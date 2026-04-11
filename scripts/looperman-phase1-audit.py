#!/usr/bin/env python3
"""Summarize dense-hit baseline behavior from Mac validation output.

Input: JSON emitted by run-openclaw-masterofdrums-validation.sh when run against
looperman sources. The script extracts, per source:
- analyzer timing provenance
- stage-2 event merge usage and candidate counts
- warning/dedupe/filter signals
- pipeline run ids and artifact URIs

This is the Phase 1 audit baseline so later tuning passes can compare where
lane-event density is being lost before chart mapping.
"""

from __future__ import annotations

import argparse
import json
import pathlib
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Summarize Looperman Phase 1 audit results from Mac validation JSON")
    parser.add_argument("--input", required=True, help="wrapper result JSON path, or directory of validate-analyzer JSON results")
    parser.add_argument("--output", help="optional summary JSON path")
    parser.add_argument("--markdown", help="optional markdown report path")
    return parser


def load_json(path: pathlib.Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    stripped = text.lstrip()
    candidate = stripped
    if not stripped.startswith("{"):
        lines = [line for line in text.splitlines() if line.strip()]
        json_lines = [line for line in lines if line.lstrip().startswith("{")]
        if not json_lines:
            raise RuntimeError(f"no JSON payload found in {path}")
        candidate = json_lines[-1]
    value = json.loads(candidate)
    if not isinstance(value, dict):
        raise RuntimeError(f"expected JSON object in {path}")
    return value


def analyzer_stdout_payload(item: dict[str, Any]) -> dict[str, Any] | None:
    for log in item.get("logs", []):
        stdout = log.get("stdout")
        if isinstance(stdout, str) and stdout.strip().startswith("{"):
            try:
                value = json.loads(stdout)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                return value
    return None


def first_artifact_uri(run: dict[str, Any], artifact_type: str) -> str | None:
    for artifact in run.get("artifacts", []):
        if artifact.get("type") == artifact_type:
            return artifact.get("uri")
    return None


def phase1_summary(payload: dict[str, Any]) -> dict[str, Any]:
    analyzer_items = payload.get("validate_analyzer") or []
    runs_final = payload.get("runs_final") or []

    per_source = []
    total_event_candidates = 0
    total_deduped = 0
    total_filtered = 0

    for index, analyzer in enumerate(analyzer_items):
        source = analyzer.get("source") or {}
        source_uri = source.get("source_uri")
        source_name = source.get("source_name")
        validation = analyzer.get("validation") or {}
        logs_payload = analyzer_stdout_payload(analyzer) or {}
        analysis = logs_payload.get("analysis") or {}
        runtime = (((logs_payload.get("rawAnalyzerOutput") or {}).get("object") or {}).get("_0") or {}).get("runtime")
        warnings = logs_payload.get("warnings") or []

        run = None
        for candidate in runs_final:
            if candidate.get("source_uri") == source_uri:
                run = candidate
                break
        if run is None and index < len(runs_final):
            run = runs_final[index]

        selected_backend = analysis.get("runtimeSelectedBackend")
        timing_backend = analysis.get("runtimeBackend")
        stage2_used = None
        stage2_candidates = 0
        filtered_count = 0
        deduped_count = 0
        fallback_used = analysis.get("runtimeFallbackUsed")

        for warning in warnings:
            if not isinstance(warning, str):
                continue
            if "merged " in warning and "fallback drum-event candidates" in warning:
                stage2_used = True
                parts = warning.split()
                for token in parts:
                    if token.isdigit():
                        stage2_candidates = int(token)
                        break
            if "filtered " in warning:
                for token in warning.split():
                    if token.isdigit():
                        filtered_count += int(token)
                        break
            if "deduped " in warning:
                for token in warning.split():
                    if token.isdigit():
                        deduped_count += int(token)
                        break

        total_event_candidates += stage2_candidates
        total_filtered += filtered_count
        total_deduped += deduped_count

        per_source.append(
            {
                "sourceName": source_name,
                "sourceURI": source_uri,
                "timingBackend": timing_backend,
                "selectedBackend": selected_backend,
                "fallbackUsed": fallback_used,
                "stage2Used": stage2_used,
                "stage2CandidateCount": stage2_candidates,
                "filteredCount": filtered_count,
                "dedupedCount": deduped_count,
                "analyzerWarnings": warnings,
                "estimatedTempoBPM": analysis.get("estimatedTempoBPM"),
                "confidence": analysis.get("confidence"),
                "runID": (run or {}).get("run_id"),
                "runStatus": (run or {}).get("status"),
                "audioAnalysisArtifact": first_artifact_uri(run or {}, "audio_analysis"),
                "normalizedAnalysisArtifact": first_artifact_uri(run or {}, "normalized_analysis"),
                "baseChartArtifact": first_artifact_uri(run or {}, "base_chart"),
                "finalChartArtifact": first_artifact_uri(run or {}, "final_chart"),
                "analyzerImportsOK": validation.get("imports_ok"),
                "analyzerConfigOK": validation.get("config_ok"),
            }
        )

    aggregate = {
        "sourceCount": len(per_source),
        "allStage2Used": all(item.get("stage2Used") for item in per_source) if per_source else False,
        "totalStage2CandidateCount": total_event_candidates,
        "totalFilteredCount": total_filtered,
        "totalDedupedCount": total_deduped,
        "timingBackends": sorted({item.get("timingBackend") for item in per_source if item.get("timingBackend")}),
        "selectedBackends": sorted({item.get("selectedBackend") for item in per_source if item.get("selectedBackend")}),
    }

    return {
        "status": payload.get("status"),
        "repo": payload.get("repo"),
        "mergeReadiness": payload.get("merge_readiness"),
        "aggregate": aggregate,
        "sources": per_source,
    }


def from_validate_analyzer_directory(path: pathlib.Path) -> dict[str, Any]:
    items = []
    for file in sorted(path.glob("*.json")):
        payload = load_json(file)
        data = payload.get("data") if isinstance(payload.get("data"), dict) else None
        if not data:
            continue
        items.append(data)

    synthesized = {
        "status": "validation-passed" if items else "validation-missing",
        "repo": items[0].get("repo") if items else None,
        "merge_readiness": {"go": bool(items), "reason": "validate-analyzer snapshots collected" if items else "no analyzer snapshots found"},
        "validate_analyzer": items,
        "runs_final": [],
    }
    return phase1_summary(synthesized)


def to_markdown(summary: dict[str, Any]) -> str:
    lines = []
    lines.append("# Looperman Phase 1 Audit")
    lines.append("")
    aggregate = summary.get("aggregate") or {}
    lines.append(f"- Sources: {aggregate.get('sourceCount', 0)}")
    lines.append(f"- Stage-2 candidate count: {aggregate.get('totalStage2CandidateCount', 0)}")
    lines.append(f"- Filtered candidates: {aggregate.get('totalFilteredCount', 0)}")
    lines.append(f"- Deduped candidates: {aggregate.get('totalDedupedCount', 0)}")
    lines.append(f"- Selected backends: {', '.join(aggregate.get('selectedBackends', [])) or 'none'}")
    lines.append("")
    for item in summary.get("sources", []):
        lines.append(f"## {item.get('sourceName') or item.get('sourceURI')}")
        lines.append(f"- timing backend: {item.get('timingBackend')}")
        lines.append(f"- selected backend: {item.get('selectedBackend')}")
        lines.append(f"- stage-2 used: {item.get('stage2Used')}")
        lines.append(f"- stage-2 candidates: {item.get('stage2CandidateCount')}")
        lines.append(f"- filtered: {item.get('filteredCount')}")
        lines.append(f"- deduped: {item.get('dedupedCount')}")
        lines.append(f"- confidence: {item.get('confidence')}")
        lines.append(f"- run id: {item.get('runID')}")
        warnings = item.get('analyzerWarnings') or []
        if warnings:
            lines.append("- warnings:")
            for warning in warnings:
                lines.append(f"  - {warning}")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    args = build_parser().parse_args()
    input_path = pathlib.Path(args.input)
    if input_path.is_dir():
        summary = from_validate_analyzer_directory(input_path)
    else:
        payload = load_json(input_path)
        summary = phase1_summary(payload)

    output_text = json.dumps(summary, indent=2, sort_keys=True)
    print(output_text)

    if args.output:
        pathlib.Path(args.output).write_text(output_text + "\n", encoding="utf-8")
    if args.markdown:
        pathlib.Path(args.markdown).write_text(to_markdown(summary), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
