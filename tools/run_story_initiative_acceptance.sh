#!/bin/zsh

set -euo pipefail
umask 077

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ARTIFACT_DIR="${KIZUNA_ACCEPTANCE_ARTIFACT_DIR:-$(mktemp -d /private/tmp/kizuna-story-acceptance.XXXXXX)}"
if [[ "$ARTIFACT_DIR" != /* ]]; then
    ARTIFACT_DIR="$PROJECT_ROOT/$ARTIFACT_DIR"
fi
mkdir -p "$ARTIFACT_DIR"
ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd -P)"
case "$ARTIFACT_DIR" in
    "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
        echo "KIZUNA_ACCEPTANCE_ARTIFACT_DIR must remain outside the repository" >&2
        exit 2
        ;;
esac
STORAGE_ROOT="$ARTIFACT_DIR/storage"
DERIVED_DATA="$ARTIFACT_DIR/derived-data"
GENERATION_OUTPUT="$ARTIFACT_DIR/generations.jsonl"
RATING_OUTPUT="$ARTIFACT_DIR/rating-input.jsonl"
FIXTURE_COPY="$ARTIFACT_DIR/story_initiative_scenarios.json"
FIXED_USER_HOME="$ARTIFACT_DIR/user-home"

report_artifacts() {
    echo "generation records: $GENERATION_OUTPUT"
    echo "private rating input: $RATING_OUTPUT"
    echo "isolated Kizuna storage: $STORAGE_ROOT"
}

# XCTest app hosts may exit without delivering the normal application
# termination notification while the app intentionally keeps its bundled
# server warm. Reap only llama-server processes from this run's isolated
# derived-data tree; never match a user's other runtime or LM Studio process.
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

mkdir -p "$STORAGE_ROOT" "$DERIVED_DATA" "$FIXED_USER_HOME"
cp -p "$PROJECT_ROOT/tools/story_initiative_scenarios.json" "$FIXTURE_COPY"

# macOS Kizuna uses the trusted Q4_K_M GGUF as iori's default artifact. Do not
# silently replace it with LM Studio's MLX/safetensors E2B bundle or with a
# different Q5 GGUF. If the exact artifact is unavailable, the runner still
# emits explicit blocked/error slots and the evaluator prevents blind scoring.
EXPECTED_IORI_BYTES=3416118624
EXPECTED_IORI_SHA256="eafe6431810b2a2a17f6c4b0be338364440707e10ff6648d07665e10875039a5"
EXPECTED_IORI_FILE="viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf"

IORI_MODEL_SOURCE="${KIZUNA_IORI_MODEL_PATH:-}"
IORI_MODEL_SHA256=""
IORI_MODEL_ACCEPTED=0
if [[ -n "$IORI_MODEL_SOURCE" ]]; then
    IORI_MODEL_SOURCE_DIR="$(dirname -- "$IORI_MODEL_SOURCE")"
    if [[ -d "$IORI_MODEL_SOURCE_DIR" ]]; then
        IORI_MODEL_SOURCE="$(cd -- "$IORI_MODEL_SOURCE_DIR" && pwd -P)/$(basename -- "$IORI_MODEL_SOURCE")"
    fi
fi
if [[ -n "$IORI_MODEL_SOURCE" && -f "$IORI_MODEL_SOURCE" ]]; then
    IORI_MODEL_BYTES="$(stat -L -f '%z' "$IORI_MODEL_SOURCE")"
    IORI_MODEL_SHA256="$(shasum -a 256 "$IORI_MODEL_SOURCE" | cut -d ' ' -f 1)"

    if [[ "$IORI_MODEL_BYTES" == "$EXPECTED_IORI_BYTES" && "$IORI_MODEL_SHA256" == "$EXPECTED_IORI_SHA256" ]]; then
        # In DEBUG/canary builds KizunaDataMigration treats the acceptance
        # root itself as Application Support. Do not add the real macOS
        # "Library/Application Support" prefix here or the app will never
        # discover the staged model and will report iori as not installed.
        IORI_INSTALL_DIR="$STORAGE_ROOT/VIUK/KizunaAI/LocalModels/Gemma4E4B4bit"
        mkdir -p "$IORI_INSTALL_DIR"
        IORI_INSTALL_PATH="$IORI_INSTALL_DIR/$EXPECTED_IORI_FILE"
        if [[ -e "$IORI_INSTALL_PATH" || -L "$IORI_INSTALL_PATH" ]]; then
            if [[ -L "$IORI_INSTALL_PATH" ]]; then
                echo "existing isolated iori artifact path is a symlink; use a fresh artifact directory" >&2
                exit 1
            fi
            INSTALLED_IORI_BYTES="$(stat -f '%z' "$IORI_INSTALL_PATH")"
            INSTALLED_IORI_SHA256="$(shasum -a 256 "$IORI_INSTALL_PATH" | cut -d ' ' -f 1)"
            if [[ "$INSTALLED_IORI_BYTES" != "$EXPECTED_IORI_BYTES" || "$INSTALLED_IORI_SHA256" != "$EXPECTED_IORI_SHA256" ]]; then
                echo "existing isolated iori artifact path does not match the requested verified artifact" >&2
                exit 1
            fi
        else
            IORI_STAGE_PATH="$IORI_INSTALL_PATH.partial"
            if [[ -e "$IORI_STAGE_PATH" || -L "$IORI_STAGE_PATH" ]]; then
                echo "stale partial iori artifact exists; use a fresh artifact directory" >&2
                exit 1
            fi
            # Do not symlink an external model into the app-data root. The
            # runtime's structural validator reads the file URL directly, and
            # Foundation reports a symlink's own byte count on this path.
            # Copy, hash-check, then atomically move the verified artifact into
            # the managed directory instead.
            cp -p "$IORI_MODEL_SOURCE" "$IORI_STAGE_PATH"
            STAGED_IORI_BYTES="$(stat -f '%z' "$IORI_STAGE_PATH")"
            STAGED_IORI_SHA256="$(shasum -a 256 "$IORI_STAGE_PATH" | cut -d ' ' -f 1)"
            if [[ "$STAGED_IORI_BYTES" != "$EXPECTED_IORI_BYTES" || "$STAGED_IORI_SHA256" != "$EXPECTED_IORI_SHA256" ]]; then
                echo "copied isolated iori artifact failed verification" >&2
                exit 1
            fi
            mv "$IORI_STAGE_PATH" "$IORI_INSTALL_PATH"
        fi
        IORI_MODEL_ACCEPTED=1
        echo "iori artifact accepted: $IORI_MODEL_SOURCE"
    else
        echo "iori artifact rejected (expected exact Q4_K_M; no substitution): $IORI_MODEL_SOURCE" >&2
        echo "observed bytes=$IORI_MODEL_BYTES sha256=$IORI_MODEL_SHA256" >&2
    fi
else
    echo "iori artifact not supplied; iori slots will be recorded as unavailable" >&2
fi

export KIZUNA_RUN_STORY_ACCEPTANCE=1
export KIZUNA_ACCEPTANCE_STORAGE_ROOT="$STORAGE_ROOT"
export KIZUNA_ACCEPTANCE_FIXTURE="$FIXTURE_COPY"
export KIZUNA_ACCEPTANCE_OUTPUT="$GENERATION_OUTPUT"
export KIZUNA_ACCEPTANCE_RATING_OUTPUT="$RATING_OUTPUT"

cd "$PROJECT_ROOT"

for key in \
    KIZUNA_ACCEPTANCE_LANGUAGES \
    KIZUNA_ACCEPTANCE_MODELS \
    KIZUNA_ACCEPTANCE_SCENARIOS \
    KIZUNA_ACCEPTANCE_SEEDS; do
    if [[ -n "${(P)key:-}" ]]; then
        echo "$key is not accepted by the formal full-matrix runner; unset it before running" >&2
        exit 2
    fi
done

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

# xcodebuild does not reliably forward the caller's shell environment into an
# app-hosted XCTest process. Inject the explicit runner contract into the
# generated xctestrun file instead, without changing the checked-in scheme.
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
set_xctest_environment CFFIXED_USER_HOME "$FIXED_USER_HOME"

if [[ -n "${KIZUNA_ACCEPTANCE_TURN_TIMEOUT_SECONDS:-}" ]]; then
    set_xctest_environment KIZUNA_ACCEPTANCE_TURN_TIMEOUT_SECONDS "$KIZUNA_ACCEPTANCE_TURN_TIMEOUT_SECONDS"
fi

if [[ "$IORI_MODEL_ACCEPTED" == "1" ]]; then
    set_xctest_environment KIZUNA_IORI_MODEL_PATH "$IORI_MODEL_SOURCE"
    set_xctest_environment KIZUNA_IORI_MODEL_SHA256 "$IORI_MODEL_SHA256"
fi

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

python3 tools/story_initiative_eval.py validate \
    --input "$GENERATION_OUTPUT" \
    --rating-input "$RATING_OUTPUT"
