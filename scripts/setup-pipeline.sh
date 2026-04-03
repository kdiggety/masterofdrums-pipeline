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
BOOTSTRAP_ANALYZER=false
AUTO_INSTALL_ANALYZER=false
ANALYZER_VENV_REL=".venv"
ANALYZER_VENV_PATH=""
ANALYZER_VENV_CUSTOM=false
ANALYZER_REQUIREMENTS_FILE="$ROOT_DIR/requirements.txt"

usage() {
  cat <<'EOF'
MasterOfDrums Pipeline setup

Usage:
  scripts/setup-pipeline.sh [options]

Options:
  --install-dir <path>          Project/install directory (default: repo root)
  --env-file <path>             Environment file to create/update (default: <install-dir>/.env)
  --database-path <path>        SQLite database path (default: <install-dir>/var/masterofdrums-pipeline.sqlite)
  --artifact-root <path>        Artifact root directory (default: <install-dir>/var/artifacts)
  --mode <pipeline|db>          pipeline = prepare runtime host, db = prepare storage host only
  --bootstrap-analyzer          Create analyzer helper scripts and seed analyzer env vars in .env when missing
  --auto-install-analyzer       Create repo-local venv and install analyzer Python requirements
  --analyzer-venv <path>        Analyzer venv path (default: <install-dir>/.venv)
  --requirements-file <path>    Python requirements file for analyzer bootstrap (default: <repo>/requirements.txt)
  --no-build                    Skip 'swift build -c release'
  --skip-tool-checks            Skip swift/sqlite3 availability checks
  -h, --help                    Show this help

Examples:
  # All-in-one/local install
  scripts/setup-pipeline.sh

  # All-in-one/local install + analyzer helper setup
  scripts/setup-pipeline.sh --bootstrap-analyzer

  # All-in-one/local install + analyzer helper setup + Python deps install
  scripts/setup-pipeline.sh --bootstrap-analyzer --auto-install-analyzer

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
    Recommended setup is a repo-local `.venv` with installs done via `python3 -m pip`.
    Install Python 3 plus PyTorch, ffmpeg, and `beat_this` if you want the primary ML path.
    Without those deps, the backend can still fall back to `scripts/backend-analyzer.py`.
  - `requirements.txt` is the source of truth for the checked-in Python analyzer stack.
  - `ffmpeg` is required for MP3/non-WAV validation and strongly recommended in general.
  - `--bootstrap-analyzer` writes helper scripts plus conservative analyzer env defaults.
  - `--auto-install-analyzer` performs local Python package installs inside the repo venv.
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

replace_or_append_env() {
  local file="$1"
  local key="$2"
  local value="$3"
  python3 - "$file" "$key" "$value" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text(encoding='utf-8')
lines = text.splitlines()
prefix = key + '='
for index, line in enumerate(lines):
    if line.startswith(prefix):
        if line.strip() == prefix:
            lines[index] = prefix + value
        break
else:
    if lines and lines[-1] != '':
        lines.append('')
    lines.append(prefix + value)
path.write_text('\n'.join(lines) + '\n', encoding='utf-8')
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
    --bootstrap-analyzer)
      BOOTSTRAP_ANALYZER=true
      shift
      ;;
    --auto-install-analyzer)
      BOOTSTRAP_ANALYZER=true
      AUTO_INSTALL_ANALYZER=true
      shift
      ;;
    --analyzer-venv)
      ANALYZER_VENV_PATH="$2"
      ANALYZER_VENV_CUSTOM=true
      shift 2
      ;;
    --requirements-file)
      ANALYZER_REQUIREMENTS_FILE="$2"
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
if [[ "$ANALYZER_VENV_CUSTOM" != true ]]; then
  ANALYZER_VENV_PATH="$INSTALL_DIR/$ANALYZER_VENV_REL"
fi
ANALYZER_VENV_PATH="$(abspath "$ANALYZER_VENV_PATH")"
ANALYZER_REQUIREMENTS_FILE="$(abspath "$ANALYZER_REQUIREMENTS_FILE")"
ANALYZER_VENV_PYTHON="$ANALYZER_VENV_PATH/bin/python"
ANALYZER_WRAPPER_COMMAND="\"$ANALYZER_VENV_PYTHON ./scripts/analyzer-wrapper.py --input {input} --output {output}\""
ANALYZER_PRIMARY_COMMAND="\"$ANALYZER_VENV_PYTHON ./scripts/beat-this-backend.py --input {input} --output {output}\""
ANALYZER_FALLBACK_COMMAND="\"$ANALYZER_VENV_PYTHON ./scripts/backend-analyzer.py --input {input} --output {output}\""

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

if [[ "$AUTO_INSTALL_ANALYZER" == true ]]; then
  require_command python3
  [[ -f "$ANALYZER_REQUIREMENTS_FILE" ]] || fail "requirements.txt not found at $ANALYZER_REQUIREMENTS_FILE"
fi

log "mode: $MODE"
log "install dir: $INSTALL_DIR"
log "env file: $ENV_FILE"
log "database path: $DATABASE_PATH"
log "artifact root: $ARTIFACT_ROOT"
if [[ "$BOOTSTRAP_ANALYZER" == true ]]; then
  log "analyzer venv: $ANALYZER_VENV_PATH"
  log "analyzer requirements: $ANALYZER_REQUIREMENTS_FILE"
fi

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

if [[ "$BOOTSTRAP_ANALYZER" == true ]]; then
  replace_or_append_env "$ENV_FILE" "PIPELINE_AUDIO_ANALYZER_COMMAND" "$ANALYZER_WRAPPER_COMMAND"
  replace_or_append_env "$ENV_FILE" "PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND" "$ANALYZER_PRIMARY_COMMAND"
  replace_or_append_env "$ENV_FILE" "PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND" "$ANALYZER_FALLBACK_COMMAND"
  replace_or_append_env "$ENV_FILE" "PIPELINE_ANALYZER_FALLBACK_POLICY" "on-error-or-invalid"
  replace_or_append_env "$ENV_FILE" "PIPELINE_ANALYZER_VALIDATION_MODE" "require-timing"
  replace_or_append_env "$ENV_FILE" "PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS" "300"
  replace_or_append_env "$ENV_FILE" "PIPELINE_AUDIO_ANALYZER_STDOUT_JSON" "false"
  log "seeded analyzer env vars in $ENV_FILE (blank values only are replaced)"
fi

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

cat > "$INSTALL_DIR/scripts/check-analyzer-env.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi

venv_python="$ANALYZER_VENV_PYTHON"
requirements_file="$ANALYZER_REQUIREMENTS_FILE"
status=0

printf '[analyzer-check] repo: %s\n' "$INSTALL_DIR"
printf '[analyzer-check] env file: %s\n' "$ENV_FILE"
printf '[analyzer-check] requirements: %s\n' "\$requirements_file"
printf '[analyzer-check] venv python: %s\n' "\$venv_python"

if [[ -f "\$requirements_file" ]]; then
  printf '[analyzer-check] requirements.txt: present\n'
else
  printf '[analyzer-check] requirements.txt: missing\n'
  status=1
fi

if [[ -x "\$venv_python" ]]; then
  printf '[analyzer-check] venv python: present\n'
else
  printf '[analyzer-check] venv python: missing\n'
  status=1
fi

if command -v ffmpeg >/dev/null 2>&1; then
  printf '[analyzer-check] ffmpeg: %s\n' "\$(command -v ffmpeg)"
else
  printf '[analyzer-check] ffmpeg: missing (install with: brew install ffmpeg)\n'
  status=1
fi

if command -v ffprobe >/dev/null 2>&1; then
  printf '[analyzer-check] ffprobe: %s\n' "\$(command -v ffprobe)"
else
  printf '[analyzer-check] ffprobe: missing (usually installed with ffmpeg)\n'
  status=1
fi

if [[ -x "\$venv_python" ]]; then
  "\$venv_python" - <<'PY'
import importlib.util, shutil, sys
checks = {
    'beat_this_py': bool(importlib.util.find_spec('beat_this')),
    'torch': bool(importlib.util.find_spec('torch')),
    'torchcodec': bool(importlib.util.find_spec('torchcodec')),
    'soundfile': bool(importlib.util.find_spec('soundfile')),
}
for key, value in checks.items():
    print(f'[analyzer-check] {key}: {value}')
print(f'[analyzer-check] beat_this_cli: {shutil.which("beat_this") or ""}')
if not checks['beat_this_py'] and not shutil.which('beat_this'):
    sys.exit(2)
PY
  rc=\$?
  if [[ \$rc -ne 0 ]]; then
    printf '[analyzer-check] beat_this availability: missing in repo venv/CLI; wrapper will rely on fallback backend\n'
    status=1
  fi
fi

printf '[analyzer-check] PIPELINE_AUDIO_ANALYZER_COMMAND=%s\n' "\${PIPELINE_AUDIO_ANALYZER_COMMAND:-}"
printf '[analyzer-check] PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND=%s\n' "\${PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND:-}"
printf '[analyzer-check] PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND=%s\n' "\${PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND:-}"
printf '[analyzer-check] PIPELINE_ANALYZER_FALLBACK_POLICY=%s\n' "\${PIPELINE_ANALYZER_FALLBACK_POLICY:-}"
printf '[analyzer-check] PIPELINE_ANALYZER_VALIDATION_MODE=%s\n' "\${PIPELINE_ANALYZER_VALIDATION_MODE:-}"

if [[ \$status -ne 0 ]]; then
  cat <<'EONEXT'
[analyzer-check] next steps:
  1. python3 -m venv .venv
  2. ./.venv/bin/python -m pip install --upgrade pip
  3. ./.venv/bin/python -m pip install -r requirements.txt
  4. brew install ffmpeg
  5. Re-run: scripts/check-analyzer-env.sh
EONEXT
fi

exit \$status
EOF
chmod +x "$INSTALL_DIR/scripts/check-analyzer-env.sh"

cat > "$INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
python3 -m venv "$ANALYZER_VENV_PATH"
"$ANALYZER_VENV_PYTHON" -m pip install --upgrade pip
"$ANALYZER_VENV_PYTHON" -m pip install -r "$ANALYZER_REQUIREMENTS_FILE"
cat <<'EONEXT'
Analyzer venv bootstrap finished.
If ffmpeg is still missing on macOS, install it with:
  brew install ffmpeg
Then run:
  scripts/check-analyzer-env.sh
EONEXT
EOF
chmod +x "$INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh"

cat > "$INSTALL_DIR/scripts/run-validate-analyzer.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$INSTALL_DIR"
if [[ \$# -lt 1 ]]; then
  cat <<'EOUSAGE' >&2
Usage:
  scripts/run-validate-analyzer.sh <audio-file-path> [requested-by]
EOUSAGE
  exit 1
fi
input_path="\$1"
requested_by="\${2:-cli}"
abs_input="\$(python3 - "\$input_path" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]))
PY
)"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
swift run MasterOfDrumsPipeline validate-audio-analyzer \
  --source-uri "file://\$abs_input" \
  --source-type file \
  --requested-by "\$requested_by" \
  --output-path /tmp/masterofdrums-audio-analysis.json
printf 'validation output: %s\n' /tmp/masterofdrums-audio-analysis.json
EOF
chmod +x "$INSTALL_DIR/scripts/run-validate-analyzer.sh"

if [[ "$AUTO_INSTALL_ANALYZER" == true ]]; then
  log "bootstrapping analyzer venv and installing Python requirements"
  "$INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh"
fi

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
  $INSTALL_DIR/scripts/check-analyzer-env.sh
  $INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh
  $INSTALL_DIR/scripts/run-validate-analyzer.sh

Useful commands:
  cd $INSTALL_DIR
  scripts/run-worker.sh --stop-after-idle-polls 5
  scripts/run-enqueue-audio-ingest.sh --source-uri file:///path/to/audio.wav --source-type file --requested-by ken
  swift run MasterOfDrumsPipeline list-jobs
  swift run MasterOfDrumsPipeline list-events --limit 20

Analyzer bootstrap / validation:
  scripts/check-analyzer-env.sh
  scripts/bootstrap-analyzer-venv.sh
  scripts/run-validate-analyzer.sh /path/to/test.wav
  python3 ./scripts/test-analyzer-wrapper.py

Recommended analyzer env shape:
  PIPELINE_AUDIO_ANALYZER_COMMAND=$ANALYZER_WRAPPER_COMMAND
  PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND=$ANALYZER_PRIMARY_COMMAND
  PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND=$ANALYZER_FALLBACK_COMMAND
  PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid
  PIPELINE_ANALYZER_VALIDATION_MODE=require-timing

Separate DB host note:
  If you're pointing PIPELINE_DATABASE_PATH at a mounted remote share, validate file locking
  and be conservative. SQLite is the current MVP store, not the final multi-host database design.
EOF
