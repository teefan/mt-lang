#!/usr/bin/env python3
"""Measure a child's peak RSS (wait4 rusage) and wall time.

A reproducible whole-program memory meter for the compiler: `ru_maxrss` is
VmHWM, so the number is comparable with the session-149 baseline figures.

    tools/peak_rss.py -- <command> [args...]

Prints one line to stderr: `hwm=<KiB> KiB wall=<seconds> s rc=<code>`.
"""

import os
import resource
import subprocess
import sys
import time


def main(argv):
    if len(argv) > 1 and argv[1] == "--":
        argv = [argv[0]] + argv[2:]
    if len(argv) < 2:
        print("usage: peak_rss.py -- <command> [args...]", file=sys.stderr)
        return 2

    started = time.monotonic()
    proc = subprocess.Popen(argv[1:])
    _, status, usage = os.wait4(proc.pid, 0)
    wall = time.monotonic() - started
    proc.returncode = os.waitstatus_to_exitcode(status)
    print(
        f"hwm={usage.ru_maxrss} KiB wall={wall:.2f} s rc={proc.returncode}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
