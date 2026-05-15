#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
from urllib.request import urlopen


def probe(url: str, timeout: float = 4.0) -> dict:
    try:
        with urlopen(url, timeout=timeout) as r:
            body = r.read(1000).decode('utf-8', errors='ignore')
            return {'url': url, 'ok': True, 'status': getattr(r, 'status', 200), 'body': body}
    except Exception as e:
        return {'url': url, 'ok': False, 'error': str(e)}


def main() -> int:
    ap = argparse.ArgumentParser(description='Smoke matrix for local endpoints.')
    ap.add_argument('--out', default='runtime/dropzone/reports/smoke_matrix.json')
    ap.add_argument('--endpoints', nargs='*', default=[
        'http://127.0.0.1:8081/health',
        'http://127.0.0.1:8090/sse',
    ])
    args = ap.parse_args()

    results = [probe(u) for u in args.endpoints]
    report = {'count': len(results), 'results': results}

    from pathlib import Path
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(f'[smoke_matrix] wrote {out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
