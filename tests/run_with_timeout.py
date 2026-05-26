#!/usr/bin/env python3
"""Run a command with process-group cleanup and captured stdout/stderr."""
from __future__ import annotations

import os
import signal
import subprocess
import sys
from pathlib import Path


def parse_timeout(value: str) -> float:
    value = value.strip()
    if value.endswith("ms"):
        return float(value[:-2]) / 1000.0
    if value.endswith("s"):
        return float(value[:-1])
    if value.endswith("m"):
        return float(value[:-1]) * 60.0
    if value.endswith("h"):
        return float(value[:-1]) * 3600.0
    return float(value)


def main(argv: list[str]) -> int:
    if len(argv) < 5:
        print("usage: run_with_timeout.py TIMEOUT OUT ERR COMMAND [ARG...]", file=sys.stderr)
        return 2

    timeout_s = parse_timeout(argv[1])
    out_path = Path(argv[2])
    err_path = Path(argv[3])
    cmd = argv[4:]

    env = os.environ.copy()
    env.setdefault("DOCK2FLOX_SERVICES", "container")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    err_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("wb") as stdout, err_path.open("wb") as stderr:
        proc = subprocess.Popen(
            cmd,
            stdout=stdout,
            stderr=stderr,
            env=env,
            start_new_session=True,
        )
        try:
            return proc.wait(timeout=timeout_s)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()
            with err_path.open("ab") as ef:
                ef.write(("\n[dock2flox-test] timeout after %s running: %s\n" % (argv[1], " ".join(cmd))).encode())
            return 124


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
