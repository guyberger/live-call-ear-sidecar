#!/usr/bin/env python3
"""Double-fork capture | ear.py so the sidecar survives the launching shell."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time


def _child() -> None:
    cap = json.loads(os.environ["EAR_CAP_CMD"])
    py = os.environ["EAR_PYTHON"]
    ear = os.environ["EAR_PY"]
    out = os.environ["EAR_OUT"]
    session = os.environ["EAR_SESSION"]
    log_path = os.environ["EAR_LOG"]
    pid_file = os.environ["EAR_PID_FILE"]
    extra = json.loads(os.environ.get("EAR_EXTRA", "[]"))

    os.chdir(os.path.dirname(ear) or ".")
    os.umask(0o022)
    dn = os.open(os.devnull, os.O_RDWR)
    os.dup2(dn, 0)

    logf = open(log_path, "a", buffering=1)
    cap_proc = subprocess.Popen(
        cap,
        stdout=subprocess.PIPE,
        stderr=logf,
        start_new_session=True,
    )
    ear_cmd = [py, "-u", ear, "--out", out, "--session-id", session, *extra]
    ear_proc = subprocess.Popen(
        ear_cmd,
        stdin=cap_proc.stdout,
        stdout=logf,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        env=os.environ.copy(),
    )
    if cap_proc.stdout is not None:
        cap_proc.stdout.close()
    with open(pid_file, "w") as f:
        f.write(f"{os.getpid()}\n{cap_proc.pid}\n{ear_proc.pid}\n")
        f.flush()
    ear_proc.wait()
    if cap_proc.poll() is None:
        cap_proc.terminate()
        try:
            cap_proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            cap_proc.kill()
    os._exit(ear_proc.returncode or 0)


def main() -> int:
    if os.fork() > 0:
        time.sleep(0.25)
        return 0
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    signal_ignore()
    _child()
    return 0


def signal_ignore() -> None:
    import signal

    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)


if __name__ == "__main__":
    raise SystemExit(main())
