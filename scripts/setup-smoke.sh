#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR=""
KEEP_WORKDIR=false

usage() {
  cat <<'EOF'
Usage: scripts/setup-smoke.sh [options]

Runs a lightweight smoke check around scripts/setup-pipeline.sh by:
  - provisioning an isolated temp install root
  - stubbing `swift run` so setup can complete without a real build
  - verifying generated helper scripts and seeded env values
  - re-running setup to confirm existing non-blank env values are preserved

Options:
  --workdir <path>   Reuse an explicit temp/work directory instead of creating one.
  --keep-workdir     Do not delete the generated temp/work directory.
  --help             Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=true
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "[setup-smoke] unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/masterofdrums-pipeline-setup-smoke.XXXXXX")"
else
  mkdir -p "$WORKDIR"
fi

cleanup() {
  if [[ "$KEEP_WORKDIR" == true ]]; then
    echo "[setup-smoke] preserved workdir: $WORKDIR" >&2
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

assert_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "[setup-smoke] missing expected file: $path" >&2
    exit 1
  fi
}

assert_executable() {
  local path="$1"
  if [[ ! -x "$path" ]]; then
    echo "[setup-smoke] expected executable file: $path" >&2
    exit 1
  fi
}

assert_contains() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$path"; then
    echo "[setup-smoke] expected $path to contain: $needle" >&2
    exit 1
  fi
}

assert_not_contains() {
  local path="$1"
  local needle="$2"
  if grep -Fq "$needle" "$path"; then
    echo "[setup-smoke] expected $path to NOT contain: $needle" >&2
    exit 1
  fi
}

INSTALL_DIR="$WORKDIR/install"
ENV_FILE="$WORKDIR/config/pipeline.env"
DATABASE_PATH="$WORKDIR/state/pipeline.sqlite"
ARTIFACT_ROOT="$WORKDIR/state/artifacts"
FAKE_BIN="$WORKDIR/fake-bin"
FAKE_SWIFT_LOG="$WORKDIR/fake-swift.log"
SETUP_LOG="$WORKDIR/setup.log"
RERUN_LOG="$WORKDIR/setup-rerun.log"

mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/swift" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'swift %s\n' "\$*" >> "$FAKE_SWIFT_LOG"
if [[ "\${1:-}" == "run" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "build" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN/swift"

export PATH="$FAKE_BIN:$PATH"

echo "[setup-smoke] first setup run"
(
  cd "$ROOT_DIR"
  scripts/setup-pipeline.sh \
    --install-dir "$INSTALL_DIR" \
    --env-file "$ENV_FILE" \
    --database-path "$DATABASE_PATH" \
    --artifact-root "$ARTIFACT_ROOT" \
    --bootstrap-analyzer \
    --analyzer-venv "$INSTALL_DIR/custom-venv" \
    --no-build \
    --skip-tool-checks
) 2>&1 | tee "$SETUP_LOG"

assert_file "$ENV_FILE"
assert_contains "$ENV_FILE" "PIPELINE_DATABASE_PATH=$DATABASE_PATH"
assert_contains "$ENV_FILE" "PIPELINE_ARTIFACT_ROOT=$ARTIFACT_ROOT"
assert_contains "$ENV_FILE" 'PIPELINE_AUDIO_ANALYZER_COMMAND="'$INSTALL_DIR'/custom-venv/bin/python ./scripts/analyzer-wrapper.py --input {input} --output {output}"'
assert_contains "$ENV_FILE" 'PIPELINE_ANALYZER_PRIMARY_BACKEND_COMMAND="'$INSTALL_DIR'/custom-venv/bin/python ./scripts/beat-this-backend.py --input {input} --output {output}"'
assert_contains "$ENV_FILE" 'PIPELINE_ANALYZER_FALLBACK_BACKEND_COMMAND="'$INSTALL_DIR'/custom-venv/bin/python ./scripts/backend-analyzer.py --input {input} --output {output}"'
assert_contains "$ENV_FILE" 'PIPELINE_ANALYZER_FALLBACK_POLICY=on-error-or-invalid'
assert_contains "$ENV_FILE" 'PIPELINE_ANALYZER_VALIDATION_MODE=require-timing'
assert_contains "$ENV_FILE" 'PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300'
assert_contains "$ENV_FILE" 'PIPELINE_AUDIO_ANALYZER_STDOUT_JSON=false'

for helper in \
  "$INSTALL_DIR/scripts/run-init-db.sh" \
  "$INSTALL_DIR/scripts/run-worker.sh" \
  "$INSTALL_DIR/scripts/run-enqueue-audio-ingest.sh" \
  "$INSTALL_DIR/scripts/check-analyzer-env.sh" \
  "$INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh" \
  "$INSTALL_DIR/scripts/run-validate-analyzer.sh"
do
  assert_file "$helper"
  assert_executable "$helper"
done

assert_contains "$INSTALL_DIR/scripts/run-init-db.sh" "source \"$ENV_FILE\""
assert_contains "$INSTALL_DIR/scripts/run-init-db.sh" "exec swift run MasterOfDrumsPipeline init-db"
assert_contains "$INSTALL_DIR/scripts/run-worker.sh" 'exec swift run MasterOfDrumsPipeline worker "$@"'
assert_contains "$INSTALL_DIR/scripts/run-enqueue-audio-ingest.sh" 'exec swift run MasterOfDrumsPipeline enqueue-audio-ingest "$@"'
assert_contains "$INSTALL_DIR/scripts/check-analyzer-env.sh" "venv_python=\"$INSTALL_DIR/custom-venv/bin/python\""
assert_contains "$INSTALL_DIR/scripts/check-analyzer-env.sh" "requirements_file=\"$ROOT_DIR/requirements.txt\""
assert_contains "$INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh" "python3 -m venv \"$INSTALL_DIR/custom-venv\""
assert_contains "$INSTALL_DIR/scripts/bootstrap-analyzer-venv.sh" "\"$INSTALL_DIR/custom-venv/bin/python\" -m pip install -r \"$ROOT_DIR/requirements.txt\""
assert_contains "$INSTALL_DIR/scripts/run-validate-analyzer.sh" "swift run MasterOfDrumsPipeline validate-audio-analyzer"
assert_contains "$SETUP_LOG" "[setup] skipping release build"
assert_contains "$SETUP_LOG" "[setup] initializing database"
assert_contains "$FAKE_SWIFT_LOG" "swift run MasterOfDrumsPipeline init-db"

python3 - "$ENV_FILE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
text = text.replace('PIPELINE_ANALYZER_VALIDATION_MODE=require-timing', 'PIPELINE_ANALYZER_VALIDATION_MODE=custom-mode')
text = text.replace('PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300', 'PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=123')
path.write_text(text, encoding='utf-8')
PY

echo "[setup-smoke] second setup run (preserve existing values)"
(
  cd "$ROOT_DIR"
  scripts/setup-pipeline.sh \
    --install-dir "$INSTALL_DIR" \
    --env-file "$ENV_FILE" \
    --database-path "$DATABASE_PATH" \
    --artifact-root "$ARTIFACT_ROOT" \
    --bootstrap-analyzer \
    --analyzer-venv "$INSTALL_DIR/custom-venv" \
    --no-build \
    --skip-tool-checks
) 2>&1 | tee "$RERUN_LOG"

assert_contains "$ENV_FILE" 'PIPELINE_ANALYZER_VALIDATION_MODE=custom-mode'
assert_contains "$ENV_FILE" 'PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=123'
assert_not_contains "$ENV_FILE" 'PIPELINE_ANALYZER_VALIDATION_MODE=require-timing'
assert_not_contains "$ENV_FILE" 'PIPELINE_AUDIO_ANALYZER_TIMEOUT_SECONDS=300'
assert_contains "$RERUN_LOG" "[setup] env file already exists; preserving existing values"

cat <<EOF
[setup-smoke] PASS
[setup-smoke] workdir: $WORKDIR
[setup-smoke] install dir: $INSTALL_DIR
[setup-smoke] env file: $ENV_FILE
[setup-smoke] fake swift log: $FAKE_SWIFT_LOG
[setup-smoke] setup logs:
  $SETUP_LOG
  $RERUN_LOG
EOF
