#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RUNTIME_DIR="${1:-$REPO_ROOT/KizunaAI/AI/LocalRuntime}"
EXPECTED_REVISION="llama.cpp b10434 (7e4c0a96880dae4fc4268ad441f8a6446bd5460a)"

required_files=(
  llama-cli
  llama-server
  llama-cli.source-revision
  llama-server.source-revision
)

for file in "${required_files[@]}"; do
  path="$RUNTIME_DIR/$file"
  if [[ ! -e "$path" ]]; then
    echo "missing local runtime artifact: $path" >&2
    exit 1
  fi
done

for runner in llama-cli llama-server; do
  if [[ ! -x "$RUNTIME_DIR/$runner" ]]; then
    echo "local runtime runner is not executable: $RUNTIME_DIR/$runner" >&2
    exit 1
  fi
done

for revision_file in llama-cli.source-revision llama-server.source-revision; do
  revision="$(tr -d '\r\n' < "$RUNTIME_DIR/$revision_file")"
  if [[ "$revision" != "$EXPECTED_REVISION" ]]; then
    echo "unexpected llama.cpp revision in $revision_file: $revision" >&2
    exit 1
  fi
done

version_output="$(LC_ALL=C "$RUNTIME_DIR/llama-server" --version 2>&1)"
if [[ "$version_output" != *"build 10434"* || "$version_output" != *"7e4c0a968"* ]]; then
  echo "unexpected llama-server version:" >&2
  echo "$version_output" >&2
  exit 1
fi

if ! command -v dyld_info >/dev/null 2>&1; then
  echo "dyld_info is required to validate macOS runtime dependencies" >&2
  exit 1
fi

while IFS= read -r -d '' artifact; do
  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    dependency_name="${dependency##*/}"
    if [[ ! -e "$RUNTIME_DIR/$dependency_name" ]]; then
      echo "missing @rpath dependency for $(basename "$artifact"): $dependency_name" >&2
      exit 1
    fi
  done < <(
    dyld_info -dependents "$artifact" 2>/dev/null \
      | sed -n -E 's/^[[:space:]]*@rpath\/([^[:space:]]+).*$/\1/p' \
      | sort -u
  )
done < <(
  find "$RUNTIME_DIR" -maxdepth 1 -type f \( -name 'llama-cli' -o -name 'llama-server' -o -name '*.dylib' \) -print0
)

echo "Local macOS runtime bundle is complete: $EXPECTED_REVISION"
