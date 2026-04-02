#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$ROOT_DIR"
ENV_FILE="$ROOT_DIR/.env"
DATABASE_PATH="$ROOT_DIR/var/masterofdrums-pipeline.sqlite"
ARTIFACT_ROOT="$ROOT_DIR/var/artifacts"
BUILD_BIN=true
SKIP_TOOL_CHECKS=false
MODE="pipeline"

usage() {
  cat <<'EOF'
MasterOfDrums Pipeline setup

Usage:
  scripts/setup-pipeline.sh [options]

Options:
  --install-dir <path>      Project/install directory (default: repo root)
  --env-file <path>         Environment file to create/update (default: <install-dir>/.env)
  --database-path <path>    SQLite database path (default: <install-dir>/var/masterofdrums-pipeline.sqlite)
  --artifact-root <path>    Artifact root directory (default: <install-dir>/var/artifacts)
  --mode <pipeline|db>      pipeline = prepare runtime host, db = prepare storage host only
  --no-build                Skip 'swift build -c release'
  --skip-tool-checks        Skip swift/sqlite3 availability checks
  -h, --help                Show this help

Examples:
  # All-in-one/local install
  scripts/setup-pipeline.sh

  # Pipeline host using a mounted remote volume for DB + artifacts
  scripts/setup-pipeline.sh \
    --database-path /Volumes/mod-pipeline-db/masterofdrums-pipeline.sqlite \
    --artifact-root /Volumes/mod-pipeline-db/artifacts

  # Storage/DB host prep only (creates directories, no build)
  scripts/setup-pipeline.sh \
    --mode db \
    --database-path /srv/masterofdrums/masterofdrums-pipeline.sqlite \
    --artifact-root /srv/masterofdrums/artifacts \
    --no-build

Notes:
  - The current pipeline uses SQLite, not Postgres/MySQL.
  - The default analyzer path is `scripts/analyzer-wrapper.py` -> `scripts/beat-this-backend.py`.
    Install Python 3 plus PyTorch, ffmpeg, and `beat_this` if you want the primary ML path.
    Without those deps, the backend can still fall back to `scripts/backend-analyzer.py`.
  - "Separate DB machine" is only practical today if the pipeline host can mount
    a remote volume and SQLite locking works correctly on that filesystem.
  - For production-grade multi-host separation, plan to move the pipeline to a
    network database before relying on this long-term.
EOF
}

log() {
  printf '[setup] %s\n' "$*"
}

fail() {
  printf '[setup] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

abspath() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --database-path)
      DATABASE_PATH="$2"
      shift 2
      ;;
    --artifact-root)
      ARTIFACT_ROOT="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --no-build)
      BUILD_BIN=false
      shift
      ;;
    --skip-tool-checks)
      SKIP_TOOL_CHECKS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ "$MODE" != "pipeline" && "$MODE" != "db" ]]; then
  fail "Invalid --mode '$MODE'. Expected 'pipeline' or 'db'."
fi

INSTALL_DIR="$(abspath "$INSTALL_DIR")"
ENV_FILE="$(abspath "$ENV_FILE")"
DATABASE_PATH="$(abspath "$DATABASE_PATH")"
ARTIFACT_ROOT="$(abspath "$ARTIFACT_ROOT")"

DB_DIR="$(dirname "$DATABASE_PATH")"
ENV_DIR="$(dirname "$ENV_FILE")"
RELEASE_BIN="$INSTALL_DIR/.build/release/MasterOfDrumsPipeline"
EXAMPLE_ENV="$ROOT_DIR/Config/pipeline.example.env"

[[ -f "$EXAMPLE_ENV" ]] || fail "Example env file not found at $EXAMPLE_ENV"

if [[ "$SKIP_TOOL_CHECKS" != true ]]; then
  require_command python3
  if [[ "$MODE" == "pipeline" ]]; then
    require_command swift
    require_command sqlite3
  fi
fi

log "mode: $MODE"
log "install dir: $INSTALL_DIR"
log "env file: $ENV_FILE"
log "database path: $DATABASE_PATH"
log "artifact root: $ARTIFACT_ROOT"

mkdir -p "$ENV_DIR" "$DB_DIR" "$ARTIFACT_ROOT"

if [[ "$MODE" == "db" ]]; then
  if [[ ! -f "$DATABASE_PATH" ]]; then
    touch "$DATABASE_PATH"
    log "created database file placeholder: $DATABASE_PATH"
  else
    log "database file already exists: $DATABASE_PATH"
  fi

  cat <<EOF

Storage host prepared.

Next step on the pipeline host:
  1. Mount this directory/path so the pipeline machine can reach:
       $DATABASE_PATH
       $ARTIFACT_ROOT
  2. Run this script there in pipeline mode and point it at the mounted paths.

Reminder:
  SQLite over network storage can be fragile depending on the filesystem and lock semantics.
  Treat this as a transitional setup until the pipeline moves to a network database.
EOF
  exit 0
fi

mkdir -p "$INSTALL_DIR/var" "$INSTALL_DIR/scripts"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$EXAMPLE_ENV" "$ENV_FILE"
  log "created env file from template"
else
  log "env file already exists; preserving existing values"
fi

python3 - "$ENV_FILE" "$DATABASE_PATH" "$ARTIFACT_ROOT" <<'PY'
import pathlib, sys
env_path = pathlib.Path(sys.argv[1])
database_path = sys.argv[2]
artifact_root = sys.argv[3]
text = env_path.read_text()
replacements = {
    'PIPELINE_DATABASE_PATH=./var/masterofdrums-pipeline.sqlite': f'PIPELINE_DATABASE_PATH={database_path}',
    'PIPELINE_ARTIFACT_ROOT=./var/artifacts': f'PIPELINE_ARTIFACT_ROOT={artifact_root}',
}
for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new)
    elif new.split('=')[0] not in text:
        text += f'\n{new}\n'
env_path.write_text(text)
PY

cat > "$INSTALL_DIR/scripts/run-init-db.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
set -a
source "$ENV_FILE"
set +a
exec swift run MasterOfDrumsPipeline init-db
EOF
chmod +x "$INSTALL_DIR/scripts/run-init-db.sh"

cat > "$INSTALL_DIR/scripts/run-worker.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
set -a
source "$ENV_FILE"
set +a
exec swift run MasterOfDrumsPipeline worker "\$@"
EOF
chmod +x "$INSTALL_DIR/scripts/run-worker.sh"

cat > "$INSTALL_DIR/scripts/run-enqueue-audio-ingest.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
set -a
source "$ENV_FILE"
set +a
exec swift run MasterOfDrumsPipeline enqueue-audio-ingest "\$@"
EOF
chmod +x "$INSTALL_DIR/scripts/run-enqueue-audio-ingest.sh"

if [[ "$BUILD_BIN" == true ]]; then
  log "building release binary"
  (cd "$INSTALL_DIR" && swift build -c release)
  log "release binary ready at $RELEASE_BIN"
else
  log "skipping release build"
fi

log "initializing database"
(cd "$INSTALL_DIR" && set -a && source "$ENV_FILE" && set +a && swift run MasterOfDrumsPipeline init-db)

cat <<EOF

Setup complete.

Generated files:
  $ENV_FILE
  $INSTALL_DIR/scripts/run-init-db.sh
  $INSTALL_DIR/scripts/run-worker.sh
  $INSTALL_DIR/scripts/run-enqueue-audio-ingest.sh

Useful commands:
  cd $INSTALL_DIR
  scripts/run-worker.sh --stop-after-idle-polls 5
  scripts/run-enqueue-audio-ingest.sh --source-uri file:///path/to/audio.wav --source-type file --requested-by ken
  swift run MasterOfDrumsPipeline list-jobs
  swift run MasterOfDrumsPipeline list-events --limit 20

Separate DB host note:
  If you're pointing PIPELINE_DATABASE_PATH at a mounted remote share, validate file locking
  and be conservative. SQLite is the current MVP store, not the final multi-host database design.
EOF
