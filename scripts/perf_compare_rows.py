#!/usr/bin/env python3
"""Compares the last row of docs/perf/history.jsonl against the median of the
N rows before it. Internal helper for perf-compare.sh.

Refuses (exit 1) rather than reporting a comparison when the current row's
machine, macOS version, or backing_scale differs from the baseline rows —
those factors change rasterization/CPU cost enough to read as a fake
regression (an external display alone was measured at ~4x).
"""
import argparse
import json
import statistics
import sys

REGRESSION_THRESHOLD = 0.15  # 15% slower than baseline median flags a regression
IMPROVEMENT_THRESHOLD = 0.15
# Below this absolute delta (ms), a percentage swing is noise, not signal —
# e.g. scroll_scroll_notify sits near 0.02ms, where +0.01ms reads as +50%.
ABSOLUTE_FLOOR_MS = 1.0
# perf_keystroke_end is PerfHarnessTests' deliberately single-sample "first
# keystroke after load" reading (see its own comment: "a single sample
# cannot tell a startup hitch apart from a per-keystroke cost"). The harness
# already provides the stable signal for that dimension as
# perf_keystroke_end_x9 (median of 9); flag on that one, not this one.
EXCLUDED_FROM_REGRESSION = {"perf_keystroke_end"}


def load_rows(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('history_file')
    ap.add_argument('n', type=int, nargs='?', default=10,
                     help='how many prior rows to use as the baseline (default 10)')
    args = ap.parse_args()

    rows = load_rows(args.history_file)
    if len(rows) < 2:
        print(f"need at least 2 rows in {args.history_file}, have {len(rows)}", file=sys.stderr)
        sys.exit(1)

    current = rows[-1]
    candidates = rows[max(0, len(rows) - 1 - args.n):len(rows) - 1]

    def env_key(r):
        return (r.get("machine"), r.get("macos"), r.get("backing_scale"))

    current_env = env_key(current)
    baseline = [r for r in candidates if env_key(r) == current_env]

    if not baseline:
        print("REFUSED: no prior row matches this run's environment "
              f"(machine={current_env[0]!r}, macos={current_env[1]!r}, "
              f"backing_scale={current_env[2]!r}) among the last {len(candidates)} row(s).",
              file=sys.stderr)
        if candidates:
            print("Environments seen in that window:", file=sys.stderr)
            for r in candidates:
                print(f"  {r['timestamp']}: {env_key(r)}", file=sys.stderr)
        sys.exit(1)

    print(f"comparing {current['timestamp']} ({current['git_sha'][:8]}) against the median of "
          f"{len(baseline)} matching prior row(s)")
    print(f"  machine={current_env[0]}  macos={current_env[1]}  backing_scale={current_env[2]}")
    print()

    all_keys = sorted(set(current.get("metrics", {})) | {k for r in baseline for k in r.get("metrics", {})})
    regressions = []
    header = f"{'metric':<32} {'baseline (median)':>18} {'current':>12} {'delta':>10}"
    print(header)
    print("-" * len(header))
    for key in all_keys:
        cur_val = current.get("metrics", {}).get(key)
        base_vals = [r["metrics"][key] for r in baseline if key in r.get("metrics", {})]
        if cur_val is None or not base_vals:
            print(f"{key:<32} {'(missing)':>18} {'' if cur_val is None else cur_val:>12} {'':>10}")
            continue
        base_median = statistics.median(base_vals)
        if base_median == 0:
            delta_str = "n/a"
            flag = ""
        else:
            delta = (cur_val - base_median) / base_median
            delta_str = f"{delta:+.1%}"
            flag = ""
            abs_delta = abs(cur_val - base_median)
            eligible = key not in EXCLUDED_FROM_REGRESSION and abs_delta > ABSOLUTE_FLOOR_MS
            if eligible and delta > REGRESSION_THRESHOLD:
                flag = "  ⚠ regression"
                regressions.append((key, delta))
            elif eligible and delta < -IMPROVEMENT_THRESHOLD:
                flag = "  ✓ faster"
            elif key in EXCLUDED_FROM_REGRESSION:
                flag = "  (excluded: single-sample)"
        print(f"{key:<32} {base_median:>18.2f} {cur_val:>12.2f} {delta_str:>10}{flag}")

    print()
    if regressions:
        print(f"{len(regressions)} metric(s) regressed by more than {REGRESSION_THRESHOLD:.0%}:")
        for key, delta in regressions:
            print(f"  {key}: {delta:+.1%}")
        sys.exit(2)
    print("no regression above threshold")


if __name__ == '__main__':
    main()
