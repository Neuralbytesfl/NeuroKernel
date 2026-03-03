#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./profiles/amd-epyc-avx2/run_epyc_stress.sh /abs/path/to/dataset.csv

if [[ $# -lt 1 ]]; then
  echo "usage: $0 /abs/path/to/dataset.csv" >&2
  exit 1
fi

DATASET_PATH="$1"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_TEMPLATE="$ROOT_DIR/profiles/amd-epyc-avx2/epyc_v13_stress.ns"
TMP_SCRIPT="$(mktemp /tmp/epyc_stress_XXXXXX.ns)"

if [[ ! -f "$SCRIPT_TEMPLATE" ]]; then
  echo "missing template: $SCRIPT_TEMPLATE" >&2
  exit 1
fi

if [[ ! -f "$DATASET_PATH" ]]; then
  echo "missing dataset: $DATASET_PATH" >&2
  exit 1
fi

sed "s|{{DATASET_PATH}}|$DATASET_PATH|g" "$SCRIPT_TEMPLATE" > "$TMP_SCRIPT"

cd "$ROOT_DIR"
swift build -c release
./.build/arm64-apple-macosx/release/neurok runonly "$TMP_SCRIPT"

echo "done: $TMP_SCRIPT"
