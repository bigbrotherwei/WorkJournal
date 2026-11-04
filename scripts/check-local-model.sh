#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export WORKJOURNAL_LIVE_MODEL="${1:-qwen3:4b-instruct}"
printf 'Checking installed local model: %s\nUses synthetic examples only; does not read your journal.\n' "$WORKJOURNAL_LIVE_MODEL"
bash scripts/test.sh --filter LiveModelTests
