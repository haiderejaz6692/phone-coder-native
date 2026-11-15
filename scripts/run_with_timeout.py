#!/usr/bin/env python3
"""Run one command with a wall-clock deadline and process-group cleanup."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys


TIMEOUT_EXIT_STATUS = 124
TERMINATION_GRACE_SECONDS = 10


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="run a command with a bounded wall-clock duration"
    )
    parser.add_argument("--timeout-seconds", required=True, type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if arguments.command[:1] == ["--"]:
        arguments.command = arguments.command[1:]
    if not arguments.command:
        parser.error("a command is required after --")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    try:
        process = subprocess.Popen(arguments.command, start_new_session=True)
    except FileNotFoundError:
        print(f"error: command not found: {arguments.command[0]}", file=sys.stderr)
        return 127

    try:
        return process.wait(timeout=arguments.timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"error: command exceeded {arguments.timeout_seconds:g} seconds; terminating it",
            file=sys.stderr,
        )
        terminate_process_group(process)
        return TIMEOUT_EXIT_STATUS
    except KeyboardInterrupt:
        terminate_process_group(process)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
