#!/usr/bin/env python3
from __future__ import annotations
import argparse
import shutil
from pathlib import Path

PATTERNS = ['*.log', '*.jsonl', '*.tmp', '*.bak']


def main() -> int:
    ap = argparse.ArgumentParser(description='Move root clutter into dropzone/outbox.')
    ap.add_argument('--root', default='.')
    ap.add_argument('--outbox', default='runtime/dropzone/outbox')
    args = ap.parse_args()

    root = Path(args.root).resolve()
    outbox = Path(args.outbox)
    if not outbox.is_absolute():
        outbox = root / outbox
    outbox.mkdir(parents=True, exist_ok=True)

    moved = []
    for pat in PATTERNS:
        for p in root.glob(pat):
            if p.is_file():
                dst = outbox / p.name
                shutil.move(str(p), str(dst))
                moved.append(str(dst))

    print(f'[clutter_guard] moved={len(moved)} -> {outbox}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
