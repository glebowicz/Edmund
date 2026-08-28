#!/usr/bin/env bash
# Diffs the most recent row of docs/perf/history.jsonl against the median of
# the N rows before it (default 10). Refuses (exit 1) instead of comparing
# when machine, macOS version, or backing_scale differ between the current
# row and every candidate baseline row — see perf_compare_rows.py.
#
# Usage: scripts/perf-compare.sh [N]
#
# Exit codes: 0 = compared, no regression above threshold
#             1 = refused (insufficient or environment-mismatched history)
#             2 = compared, at least one metric regressed

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
history_file="$repo_root/docs/perf/history.jsonl"

if [[ ! -f "$history_file" ]]; then
    echo "no history file at $history_file — run scripts/perf-baseline.sh first" >&2
    exit 1
fi

python3 "$repo_root/scripts/perf_compare_rows.py" "$history_file" "$@"
