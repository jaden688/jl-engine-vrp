#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path

KEYWORDS = [
    r"error", r"exception", r"traceback", r"failed", r"fatal", r"denied",
    r"eaddrinuse", r"permission denied", r"operationalerror", r"http\s+4\d\d", r"http\s+5\d\d"
]


def scan_file(path: Path, regex: re.Pattern[str], limit: int) -> list[dict]:
    hits = []
    try:
        for i, line in enumerate(path.read_text(encoding='utf-8', errors='ignore').splitlines(), start=1):
            if regex.search(line):
                hits.append({"file": str(path), "line": i, "text": line[:400]})
                if len(hits) >= limit:
                    break
    except Exception as e:
        hits.append({"file": str(path), "line": 0, "text": f"READ_ERROR: {e}"})
    return hits


def main() -> int:
    ap = argparse.ArgumentParser(description='Triage logs for common failures.')
    ap.add_argument('--root', default='.', help='Repo root')
    ap.add_argument('--out', default='runtime/dropzone/reports/triage_report.json', help='Output JSON report path')
    ap.add_argument('--per-file-limit', type=int, default=80)
    args = ap.parse_args()

    root = Path(args.root).resolve()
    out = Path(args.out)
    if not out.is_absolute():
        out = root / out
    out.parent.mkdir(parents=True, exist_ok=True)

    regex = re.compile('|'.join(KEYWORDS), re.IGNORECASE)
    files = list(root.glob('*.log')) + list((root / 'logs').glob('*.log'))

    findings = []
    for f in sorted(set(files)):
        findings.extend(scan_file(f, regex, args.per_file_limit))

    payload = {
        'root': str(root),
        'files_scanned': len(files),
        'finding_count': len(findings),
        'findings': findings,
    }
    out.write_text(json.dumps(payload, indent=2), encoding='utf-8')
    print(f'[triage_logs] wrote {out} (findings={len(findings)})')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
