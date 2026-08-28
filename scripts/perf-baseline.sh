#!/usr/bin/env bash
# Runs the MD_PERF timing harnesses (PerfHarnessTests, ScrollPerfHarnessTests)
# against the pinned Phase 2 fixture and appends one JSON row to
# docs/perf/history.jsonl. Local trend tracking only — never a CI gate; see
# Tests/EdmundTests/PerfCountersTests.swift for the counter-based CI gate.
#
# Both harnesses build their editor via makeEditor() (shipped defaults), not
# makePerfEditor() — recorded as profile "shipped-defaults" below rather than
# silently implying otherwise. PerfHarnessTests times a synthetic generated
# document (MD_PERF_BYTES, default 1.5MB); ScrollPerfHarnessTests is pointed
# at the pinned perf-real-40k.md fixture via MD_PERF_FILE, which is the
# "pinned fixtures" run this script exists to produce.
#
# Medians/p95/max: both harnesses already compute these internally across
# many repeats within one run (ScrollPerfHarnessTests across dozens of scroll
# frames, PerfHarnessTests across 9 keystroke repeats) — reused here rather
# than re-implemented. This script runs each harness once per invocation; the
# "alternating interleaved rounds, never A-then-B" concern in the plan this
# script was built from applies to comparing two configurations head-to-head
# (SettingsPerfComparisonTests already does that internally), not to trend
# rows recorded one commit at a time — trend comparison across rows is what
# perf-compare.sh is for.
#
# Usage:
#   scripts/perf-baseline.sh [--bytes N] [--compare [N]]
#
#   --bytes N   overrides MD_PERF_BYTES for PerfHarnessTests (default 1500000)
#   --compare   after appending, run perf-compare.sh (optionally passing N)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fixture="$repo_root/Tests/EdmundTests/Fixtures/perf-real-40k.md"
history_file="$repo_root/docs/perf/history.jsonl"
mkdir -p "$(dirname "$history_file")"

bytes=""
do_compare=false
compare_n=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --bytes)
            bytes="$2"; shift 2 ;;
        --compare)
            do_compare=true
            if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then compare_n="$2"; shift 2; else shift 1; fi
            ;;
        *)
            echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$fixture" ]]; then
    echo "pinned fixture not found: $fixture" >&2
    exit 1
fi

# One invocation for both harnesses. --filter is a substring match on the
# test ID, and "ScrollPerfHarnessTests" contains "PerfHarnessTests" as a
# literal substring — filtering for "PerfHarnessTests" alone pulls in
# ScrollPerfHarnessTests too (and it then fails without MD_PERF_FILE), so
# both harnesses always run together against the same env, filtered by the
# "Perf" substring they both share.
echo "== running PerfHarnessTests + ScrollPerfHarnessTests (MD_PERF, MD_PERF_FILE=$(basename "$fixture")${bytes:+, MD_PERF_BYTES=$bytes}) ==" >&2
if [[ -n "$bytes" ]]; then
    combined_out="$(MD_PERF=1 MD_PERF_FILE="$fixture" MD_PERF_BYTES="$bytes" swift test --filter Perf 2>&1)" || {
        echo "$combined_out" >&2
        echo "perf harnesses failed — see output above" >&2
        exit 1
    }
else
    combined_out="$(MD_PERF=1 MD_PERF_FILE="$fixture" swift test --filter Perf 2>&1)" || {
        echo "$combined_out" >&2
        echo "perf harnesses failed — see output above" >&2
        exit 1
    }
fi

git_sha="$(git rev-parse HEAD)"
git_dirty="false"
[[ -n "$(git status --porcelain)" ]] && git_dirty="true"
machine="$(sysctl -n hw.model)"
macos="$(sw_vers -productVersion)"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
perf_bytes="${bytes:-1500000}"
fixture_name="$(basename "$fixture")"

row="$(printf '%s' "$combined_out" | python3 "$repo_root/scripts/perf_parse_row.py" \
    --timestamp "$timestamp" --git-sha "$git_sha" --git-dirty "$git_dirty" \
    --machine "$machine" --macos "$macos" \
    --corpus-perf "synthetic-${perf_bytes}b" --corpus-scroll "$fixture_name" \
    --profile "shipped-defaults")"

echo "$row" >> "$history_file"
echo "recorded row:" >&2
echo "$row" | python3 -m json.tool >&2

if $do_compare; then
    if [[ -n "$compare_n" ]]; then
        "$repo_root/scripts/perf-compare.sh" "$compare_n"
    else
        "$repo_root/scripts/perf-compare.sh"
    fi
fi
