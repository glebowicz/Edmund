#!/usr/bin/env python3
"""Parses [MD_PERF]/[MD_SCROLL] harness output (stdin) plus metadata (argv)
into one JSON history row, printed to stdout. Internal helper for
perf-baseline.sh — not meant to be run standalone.
"""
import argparse
import json
import re
import sys

METRIC_RE = re.compile(r'^\[MD_(PERF|SCROLL)\]\s+([^:]+):\s+([\d.]+)\s*ms')
BACKING_SCALE_RE = re.compile(r'^\[MD_SCROLL\] backing scale:\s+([\d.]+)x')


def slug(label: str) -> str:
    key = label.strip().lower()
    key = re.sub(r'[^a-z0-9]+', '_', key).strip('_')
    return key


def parse(text: str):
    metrics = {}
    backing_scale = None
    for line in text.splitlines():
        m = BACKING_SCALE_RE.match(line)
        if m:
            backing_scale = float(m.group(1))
            continue
        m = METRIC_RE.match(line)
        if m:
            prefix, label, value = m.groups()
            ns = 'perf' if prefix == 'PERF' else 'scroll'
            metrics[f'{ns}_{slug(label)}'] = float(value)
    return metrics, backing_scale


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--timestamp', required=True)
    ap.add_argument('--git-sha', required=True)
    ap.add_argument('--git-dirty', required=True)
    ap.add_argument('--machine', required=True)
    ap.add_argument('--macos', required=True)
    ap.add_argument('--corpus-perf', required=True)
    ap.add_argument('--corpus-scroll', required=True)
    ap.add_argument('--profile', required=True)
    args = ap.parse_args()

    text = sys.stdin.read()
    metrics, backing_scale = parse(text)
    if backing_scale is None:
        print("warning: no backing scale found in ScrollPerfHarnessTests output", file=sys.stderr)
    if not metrics:
        print("error: no [MD_PERF]/[MD_SCROLL] metric lines found in harness output", file=sys.stderr)
        sys.exit(1)

    row = {
        "timestamp": args.timestamp,
        "git_sha": args.git_sha,
        "git_dirty": args.git_dirty == "true",
        "machine": args.machine,
        "macos": args.macos,
        "backing_scale": backing_scale,
        "corpus_perf": args.corpus_perf,
        "corpus_scroll": args.corpus_scroll,
        "profile": args.profile,
        "metrics": metrics,
    }
    print(json.dumps(row, sort_keys=True))


if __name__ == '__main__':
    main()
