#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_PATH="$ROOT_DIR/Tests/PipelineRuntimeTests/Fixtures/known-tone.wav"
REQUESTED_BY="smoke-harness"
WORKDIR=""
KEEP_WORKDIR=false
STOP_AFTER_IDLE_POLLS=2
SWIFT_RUN=(swift run MasterOfDrumsPipeline)

usage() {
  cat <<'EOF'
Usage: scripts/worker-smoke.sh [options]

Runs a repeatable CLI smoke harness for:
  init-db
  enqueue-audio-ingest
  worker
  list-jobs
  list-events
  list-artifacts

Options:
  --source-uri <uri>              Audio source URI or file path. Defaults to the bundled known-tone.wav fixture.
  --requested-by <value>          requested_by value recorded in the workflow. Default: smoke-harness
  --workdir <path>                Reuse an explicit temp/work directory instead of creating one.
  --keep-workdir                  Do not delete the generated temp/work directory.
  --stop-after-idle-polls <n>     Worker idle-stop threshold. Default: 2
  --help                          Show this help.

Environment overrides:
  PIPELINE_SMOKE_SWIFT_RUN        Command used instead of `swift run MasterOfDrumsPipeline`
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-uri)
      FIXTURE_PATH="$2"
      shift 2
      ;;
    --requested-by)
      REQUESTED_BY="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=true
      shift
      ;;
    --stop-after-idle-polls)
      STOP_AFTER_IDLE_POLLS="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "[smoke] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "${PIPELINE_SMOKE_SWIFT_RUN:-}" ]]; then
  # shellcheck disable=SC2206
  SWIFT_RUN=(${PIPELINE_SMOKE_SWIFT_RUN})
fi

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/masterofdrums-pipeline-smoke.XXXXXX")"
else
  mkdir -p "$WORKDIR"
fi

cleanup() {
  if [[ "$KEEP_WORKDIR" == true ]]; then
    echo "[smoke] preserved workdir: $WORKDIR" >&2
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

DB_PATH="$WORKDIR/pipeline.sqlite"
ARTIFACT_ROOT="$WORKDIR/artifacts"
ANALYZER_SCRIPT="$WORKDIR/mock-analyzer.py"
LOG_DIR="$WORKDIR/logs"
mkdir -p "$ARTIFACT_ROOT" "$LOG_DIR"

cat > "$ANALYZER_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import pathlib
import sys

input_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
if not input_path.exists():
    raise SystemExit(f"missing input fixture: {input_path}")
output_path.write_text(json.dumps({
    "analysis": {
        "audioTrackCount": 1,
        "confidence": 0.99,
        "downbeatOffsetSeconds": 0.0,
        "durationSeconds": 1.0,
        "estimatedSegmentCount": 1,
        "estimatedTempoBPM": 120.0
    },
    "beats": [0.0, 0.5, 1.0],
    "downbeats": [0.0],
    "drumEvents": [
        {"eventID": "kick-1", "label": "kick", "onsetSeconds": 0.0, "velocity": 1.0, "confidence": 0.9},
        {"eventID": "snare-1", "label": "snare", "onsetSeconds": 0.5, "velocity": 0.7, "confidence": 0.8}
    ],
    "segments": [
        {"index": 0, "startSeconds": 0.0, "endSeconds": 1.0, "label": "full_track", "confidence": 0.99}
    ],
    "warnings": ["worker-smoke"],
    "note": "worker smoke harness analyzer output"
}, indent=2), encoding="utf-8")
PY
chmod +x "$ANALYZER_SCRIPT"

if [[ "$FIXTURE_PATH" == file://* ]]; then
  SOURCE_URI="$FIXTURE_PATH"
  SOURCE_PATH="${FIXTURE_PATH#file://}"
else
  SOURCE_PATH="$FIXTURE_PATH"
  SOURCE_URI="file://$SOURCE_PATH"
fi

if [[ ! -f "$SOURCE_PATH" ]]; then
  echo "[smoke] source fixture not found: $SOURCE_PATH" >&2
  exit 1
fi

export PIPELINE_DATABASE_PATH="$DB_PATH"
export PIPELINE_ARTIFACT_ROOT="$ARTIFACT_ROOT"
export PIPELINE_AUDIO_ANALYZER_COMMAND="python3 '$ANALYZER_SCRIPT' {input} {output}"
export PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false
export PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=30

run_cli() {
  local name="$1"
  shift
  local log_path="$LOG_DIR/$name.log"
  echo "[smoke] >>> ${SWIFT_RUN[*]} $*" >&2
  (
    cd "$ROOT_DIR"
    "${SWIFT_RUN[@]}" "$@"
  ) 2>&1 | tee "$log_path"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "[smoke] assertion failed: expected $label to contain: $needle" >&2
    exit 1
  fi
}

INIT_OUTPUT="$(run_cli init-db init-db)"
ENQUEUE_OUTPUT="$(run_cli enqueue enqueue-audio-ingest --source-uri "$SOURCE_URI" --source-type file --requested-by "$REQUESTED_BY")"
WORKER_OUTPUT="$(run_cli worker worker --stop-after-idle-polls "$STOP_AFTER_IDLE_POLLS")"
JOBS_OUTPUT="$(run_cli list-jobs list-jobs)"
EVENTS_OUTPUT="$(run_cli list-events list-events --limit 20)"
ARTIFACTS_OUTPUT="$(run_cli list-artifacts list-artifacts --limit 20)"

assert_contains "$INIT_OUTPUT" "database initialized" "init-db output"
assert_contains "$ENQUEUE_OUTPUT" "enqueued audio-ingest job" "enqueue output"
assert_contains "$WORKER_OUTPUT" "job succeeded" "worker output"
assert_contains "$JOBS_OUTPUT" "audio_ingest succeeded" "list-jobs output"
assert_contains "$JOBS_OUTPUT" "audio_analyze succeeded" "list-jobs output"
assert_contains "$JOBS_OUTPUT" "chart_generate succeeded" "list-jobs output"
assert_contains "$EVENTS_OUTPUT" "type=job_enqueued" "list-events output"
assert_contains "$EVENTS_OUTPUT" "type=audio_analysis_completed" "list-events output"
assert_contains "$EVENTS_OUTPUT" "type=base_chart_created" "list-events output"
assert_contains "$ARTIFACTS_OUTPUT" "type=source_audio" "list-artifacts output"
assert_contains "$ARTIFACTS_OUTPUT" "type=audio_analysis" "list-artifacts output"
assert_contains "$ARTIFACTS_OUTPUT" "type=normalized_analysis" "list-artifacts output"
assert_contains "$ARTIFACTS_OUTPUT" "type=base_chart" "list-artifacts output"

cat <<EOF
[smoke] PASS
[smoke] workdir: $WORKDIR
[smoke] database: $DB_PATH
[smoke] artifact root: $ARTIFACT_ROOT
[smoke] source: $SOURCE_URI
[smoke] logs:
  $LOG_DIR/init-db.log
  $LOG_DIR/enqueue.log
  $LOG_DIR/worker.log
  $LOG_DIR/list-jobs.log
  $LOG_DIR/list-events.log
  $LOG_DIR/list-artifacts.log
EOF
