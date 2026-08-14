#!/bin/zsh

set -euo pipefail
umask 077

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
IORI_MODEL_SOURCE="${KIZUNA_IORI_MODEL_PATH:-}"
# Keep the app, fixture, UserDefaults, and model staging tree on the boot
# volume. A GUI test host may block while opening an external-volume path even
# when a command-line process can read the same file. The source GGUF may still
# live on the SSD; it is copied once into this isolated internal fixture.
DEFAULT_ARTIFACT_PARENT="/private/tmp"
ARTIFACT_DIR="${KIZUNA_IORI_CANARY_ARTIFACT_DIR:-$(mktemp -d "$DEFAULT_ARTIFACT_PARENT/kizuna-story-iori-canary.XXXXXX")}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
    ARTIFACT_DIR="$PROJECT_ROOT/$ARTIFACT_DIR"
fi
mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd -P)"
case "$ARTIFACT_DIR" in
    "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
        echo "KIZUNA_IORI_CANARY_ARTIFACT_DIR must remain outside the repository" >&2
        exit 2
        ;;
esac

STORAGE_ROOT="$ARTIFACT_DIR/storage"
DERIVED_DATA="$ARTIFACT_DIR/derived-data"
GENERATION_OUTPUT="$ARTIFACT_DIR/generations.jsonl"
RATING_OUTPUT="$ARTIFACT_DIR/rating-input.jsonl"
FIXTURE_COPY="$ARTIFACT_DIR/story_initiative_scenarios.json"
FIXED_USER_HOME="$ARTIFACT_DIR/user-home"
EXPECTED_IORI_BYTES=3416118624
EXPECTED_IORI_SHA256="eafe6431810b2a2a17f6c4b0be338364440707e10ff6648d07665e10875039a5"
EXPECTED_IORI_FILE="viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf"

report_artifacts() {
    echo "generation records: $GENERATION_OUTPUT"
    echo "private rating input: $RATING_OUTPUT"
    echo "isolated Kizuna storage: $STORAGE_ROOT"
}

# The app deliberately keeps a bundled server warm for normal conversation.
# An app-hosted XCTest process can be torn down without delivering the normal
# application termination notification, though. Reap only llama-server
# processes launched from this run's isolated derived-data tree so a failed or
# interrupted canary cannot poison the next run with an orphaned server.
owned_server_pids() {
    local display_derived_data="$DERIVED_DATA"
    if [[ "$display_derived_data" == /private/* ]]; then
        display_derived_data="${display_derived_data#/private}"
    fi
    ps -axo pid=,command= | awk \
        -v prefix="$DERIVED_DATA/Build/Products/" \
        -v displayPrefix="$display_derived_data/Build/Products/" \
        '((index($0, prefix) || index($0, displayPrefix)) && $0 ~ /\/llama-server([[:space:]]|$)/) {print $1}'
}

cleanup_runtime_processes() {
    local pid command display_derived_data="$DERIVED_DATA"
    if [[ "$display_derived_data" == /private/* ]]; then
        display_derived_data="${display_derived_data#/private}"
    fi
    for pid in $(owned_server_pids); do
        [[ -n "$pid" ]] || continue
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            *"$DERIVED_DATA/Build/Products/"*"/llama-server "*|*"$display_derived_data/Build/Products/"*"/llama-server "*)
                kill -TERM "$pid" 2>/dev/null || true
                ;;
        esac
    done

    for _ in {1..20}; do
        [[ -z "$(owned_server_pids)" ]] && return
        sleep 0.1
    done

    for pid in $(owned_server_pids); do
        [[ -n "$pid" ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done
}

trap 'cleanup_runtime_processes; report_artifacts' EXIT

if [[ -z "$IORI_MODEL_SOURCE" || ! -f "$IORI_MODEL_SOURCE" ]]; then
    echo "KIZUNA_IORI_MODEL_PATH must point to the trusted iori GGUF" >&2
    exit 2
fi
IORI_MODEL_SOURCE_DIR="$(dirname -- "$IORI_MODEL_SOURCE")"
IORI_MODEL_SOURCE="$(cd -- "$IORI_MODEL_SOURCE_DIR" && pwd -P)/$(basename -- "$IORI_MODEL_SOURCE")"
IORI_MODEL_BYTES="$(stat -L -f '%z' "$IORI_MODEL_SOURCE")"
IORI_MODEL_SHA256="$(shasum -a 256 "$IORI_MODEL_SOURCE" | cut -d ' ' -f 1)"
if [[ "$IORI_MODEL_BYTES" != "$EXPECTED_IORI_BYTES" || "$IORI_MODEL_SHA256" != "$EXPECTED_IORI_SHA256" ]]; then
    echo "iori canary requires the exact trusted Q4_K_M artifact" >&2
    echo "observed bytes=$IORI_MODEL_BYTES sha256=$IORI_MODEL_SHA256" >&2
    exit 2
fi

mkdir -p "$STORAGE_ROOT" "$DERIVED_DATA" "$FIXED_USER_HOME"
cp -p "$PROJECT_ROOT/tools/story_initiative_scenarios.json" "$FIXTURE_COPY"
IORI_INSTALL_DIR="$STORAGE_ROOT/VIUK/KizunaAI/LocalModels/Gemma4E4B4bit"
mkdir -p "$IORI_INSTALL_DIR"
IORI_INSTALL_PATH="$IORI_INSTALL_DIR/$EXPECTED_IORI_FILE"
IORI_STAGE_PATH="$IORI_INSTALL_PATH.partial"
if [[ -e "$IORI_INSTALL_PATH" || -L "$IORI_INSTALL_PATH" ]]; then
    if [[ -L "$IORI_INSTALL_PATH" ]]; then
        echo "existing isolated iori artifact path is a symlink" >&2
        exit 1
    fi
    INSTALLED_IORI_BYTES="$(stat -f '%z' "$IORI_INSTALL_PATH")"
    INSTALLED_IORI_SHA256="$(shasum -a 256 "$IORI_INSTALL_PATH" | cut -d ' ' -f 1)"
    if [[ "$INSTALLED_IORI_BYTES" != "$EXPECTED_IORI_BYTES" || "$INSTALLED_IORI_SHA256" != "$EXPECTED_IORI_SHA256" ]]; then
        echo "existing isolated iori artifact path does not match the requested verified artifact" >&2
        exit 1
    fi
else
    rm -f "$IORI_STAGE_PATH"
    if [[ "$(stat -f '%d' "$IORI_MODEL_SOURCE")" == "$(stat -f '%d' "$IORI_INSTALL_DIR")" ]]; then
        # A hard link keeps the staged model a regular file (unlike a symlink)
        # and avoids duplicating a multi-gigabyte local model on one volume.
        ln "$IORI_MODEL_SOURCE" "$IORI_STAGE_PATH"
    else
        cp -p "$IORI_MODEL_SOURCE" "$IORI_STAGE_PATH"
    fi
    STAGED_IORI_BYTES="$(stat -f '%z' "$IORI_STAGE_PATH")"
    STAGED_IORI_SHA256="$(shasum -a 256 "$IORI_STAGE_PATH" | cut -d ' ' -f 1)"
    if [[ "$STAGED_IORI_BYTES" != "$EXPECTED_IORI_BYTES" || "$STAGED_IORI_SHA256" != "$EXPECTED_IORI_SHA256" ]]; then
        echo "staged iori artifact failed verification" >&2
        exit 1
    fi
    mv "$IORI_STAGE_PATH" "$IORI_INSTALL_PATH"
fi

# The app writes this marker after a trusted download has completed. The
# canary stages the same SHA-256-verified official artifact locally, so it must
# reproduce that durable state instead of making startup parse a multi-GB
# unknown file synchronously. The application still performs its normal quick
# trusted-artifact validation and runtime self-check.
python3 - "$IORI_INSTALL_DIR/download-state.json" "$IORI_MODEL_SHA256" <<'PY'
import datetime
import json
import os
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
digest = sys.argv[2]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
source_url = (
    "https://huggingface.co/Shirokuma-VIUK/VIUK-Story-v2.5-GGUF/resolve/main/"
    "viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf?download=true"
)
payload = {
    "sourceURL": source_url,
    "resolvedURL": source_url,
    "expectedBytes": 3416118624,
    "eTag": None,
    "resumeDataPath": None,
    "status": "completed",
    "startedAt": now,
    "updatedAt": now,
    "lastError": None,
    "suggestedFilename": "viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf",
    "pendingValidationPath": None,
    "replacementBackupPath": None,
    "replacementInProgress": False,
    "previousInstalledFileName": None,
    "previousSourceURL": None,
    "previousResolvedURL": None,
    "previousExpectedBytes": None,
    "previousETag": None,
}
if digest != "eafe6431810b2a2a17f6c4b0be338364440707e10ff6648d07665e10875039a5":
    raise SystemExit("unexpected iori digest while writing completed state")
temporary = target.with_name(target.name + ".partial")
temporary.write_text(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
os.chmod(temporary, 0o600)
os.replace(temporary, target)
PY

cd "$PROJECT_ROOT"
xcodebuild -quiet build-for-testing \
    -project KizunaAI.xcodeproj \
    -scheme KizunaAI \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO

XCTESTRUN_PATH="$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -type f -name '*.xctestrun' -print -quit)"
if [[ -z "$XCTESTRUN_PATH" ]]; then
    echo "xctestrun specification was not generated" >&2
    exit 1
fi

set_xctest_environment() {
    local key="$1"
    local value="$2"
    /usr/bin/plutil -insert "KizunaAITests.EnvironmentVariables.$key" -string "$value" "$XCTESTRUN_PATH"
    /usr/bin/plutil -insert "KizunaAITests.TestingEnvironmentVariables.$key" -string "$value" "$XCTESTRUN_PATH"
}

set_xctest_environment KIZUNA_RUN_STORY_ACCEPTANCE "1"
set_xctest_environment KIZUNA_ACCEPTANCE_PROJECT_ROOT "$PROJECT_ROOT"
set_xctest_environment KIZUNA_ACCEPTANCE_STORAGE_ROOT "$STORAGE_ROOT"
set_xctest_environment KIZUNA_ACCEPTANCE_FIXTURE "$FIXTURE_COPY"
set_xctest_environment KIZUNA_ACCEPTANCE_OUTPUT "$GENERATION_OUTPUT"
set_xctest_environment KIZUNA_ACCEPTANCE_RATING_OUTPUT "$RATING_OUTPUT"
set_xctest_environment KIZUNA_ACCEPTANCE_LANGUAGES "ja"
set_xctest_environment KIZUNA_ACCEPTANCE_MODELS "iori"
set_xctest_environment KIZUNA_ACCEPTANCE_SCENARIOS "story-01"
set_xctest_environment KIZUNA_ACCEPTANCE_SEEDS "1"
set_xctest_environment KIZUNA_ACCEPTANCE_TURN_TIMEOUT_SECONDS "240"
set_xctest_environment KIZUNA_IORI_MODEL_PATH "$IORI_MODEL_SOURCE"
set_xctest_environment KIZUNA_IORI_MODEL_SHA256 "$IORI_MODEL_SHA256"
set_xctest_environment CFFIXED_USER_HOME "$FIXED_USER_HOME"

RESULT_BUNDLE="$ARTIFACT_DIR/result.xcresult"
if [[ -e "$RESULT_BUNDLE" ]]; then
    rm -rf "$RESULT_BUNDLE"
fi

xcodebuild -quiet test-without-building \
    -xctestrun "$XCTESTRUN_PATH" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -destination 'platform=macOS' \
    -only-testing:KizunaAITests/StoryInitiativeAcceptanceRunnerTests/testStoryInitiativeAcceptanceMatrix \
    -parallel-testing-enabled NO

python3 - "$GENERATION_OUTPUT" "$RATING_OUTPUT" "$EXPECTED_IORI_SHA256" <<'PY'
import json
import pathlib
import sys

generation_path = pathlib.Path(sys.argv[1])
rating_path = pathlib.Path(sys.argv[2])
expected_sha = sys.argv[3]
generations = [json.loads(line) for line in generation_path.read_text().splitlines() if line.strip()]
ratings = [json.loads(line) for line in rating_path.read_text().splitlines() if line.strip()]
if len(generations) != 2 or len(ratings) != 2:
    raise SystemExit(f"expected two canary records per artifact, got {len(generations)} and {len(ratings)}")
if {record.get("condition") for record in generations} != {"baseline", "initiative"}:
    raise SystemExit("canary did not produce baseline and initiative records")
for record in generations:
    if record.get("status") != "completed":
        raise SystemExit(f"canary generation did not complete: {record.get('status')}")
    if record.get("model") != "iori" or record.get("language") != "ja":
        raise SystemExit("canary matrix identity is incorrect")
    runtime = record.get("runtime") or {}
    if runtime.get("model_identity") != "viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf":
        raise SystemExit(f"unexpected runtime identity: {runtime.get('model_identity')!r}")
    if runtime.get("model_sha256") != expected_sha:
        raise SystemExit("canary runtime SHA-256 was not observed")
    if runtime.get("model_identity_observed") is not True or runtime.get("prompt_observed") is not True:
        raise SystemExit("canary runtime observation is incomplete")
for record in ratings:
    if record.get("record_type") != "rating_input" or not record.get("response_text"):
        raise SystemExit("canary rating input is incomplete")
print("iori app-path canary passed: 2 completed turns, baseline+initiative")
PY
