#!/usr/bin/env python3
from __future__ import annotations
import argparse
import json
import subprocess
import time
from pathlib import Path
from urllib.request import urlopen


def healthcheck(url: str, timeout: float = 3.0) -> tuple[bool, str]:
    try:
        with urlopen(url, timeout=timeout) as r:
            body = r.read(4000).decode('utf-8', errors='ignore')
            return True, body
    except Exception as e:
        return False, str(e)


def main() -> int:
    ap = argparse.ArgumentParser(description='Run command and verify service health.')
    ap.add_argument('--cmd', default='julia --compiled-modules=no --project=. sparkbyte.jl')
    ap.add_argument('--cwd', default='.')
    ap.add_argument('--health-url', default='http://127.0.0.1:8081/health')
    ap.add_argument('--wait-seconds', type=int, default=15)
    ap.add_argument('--out', default='runtime/dropzone/reports/repro_report.json')
    args = ap.parse_args()

    cwd = Path(args.cwd).resolve()
    out = Path(args.out)
    if not out.is_absolute():
        out = cwd / out
    out.parent.mkdir(parents=True, exist_ok=True)

    started_at = time.time()
    proc = subprocess.Popen(args.cmd, cwd=str(cwd), shell=True)
    time.sleep(max(1, args.wait_seconds))
    ok, detail = healthcheck(args.health_url)

    payload = {
        'cmd': args.cmd,
        'cwd': str(cwd),
        'pid': proc.pid,
        'health_url': args.health_url,
        'health_ok': ok,
        'health_detail': detail,
        'elapsed_seconds': round(time.time() - started_at, 2),
    }
    out.write_text(json.dumps(payload, indent=2), encoding='utf-8')
    print(f'[repro_runner] wrote {out} health_ok={ok} pid={proc.pid}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
