#!/usr/bin/env python3
"""Resolve one simulator UDID from exact runtime metadata and device inventory."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read simulator inventory {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"simulator inventory {path} must contain a JSON object")
    return value


def resolve_udid(runtimes: dict, devices: dict, version: str, name: str) -> str:
    ios_runtime_prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
    runtime_matches = [
        runtime
        for runtime in runtimes.get("runtimes", [])
        if runtime.get("version") == version
        and runtime.get("isAvailable", False)
        and str(runtime.get("identifier", "")).startswith(ios_runtime_prefix)
    ]
    if len(runtime_matches) != 1:
        raise ValueError(f"expected exactly one available iOS {version} runtime")

    identifier = runtime_matches[0].get("identifier")
    if not isinstance(identifier, str) or not identifier:
        raise ValueError(f"available iOS {version} runtime has no identifier")

    device_matches = [
        device
        for device in devices.get("devices", {}).get(identifier, [])
        if device.get("name") == name and device.get("isAvailable", False)
    ]
    if len(device_matches) != 1:
        raise ValueError(f"expected exactly one available {name} on iOS {version}")

    udid = device_matches[0].get("udid")
    if not isinstance(udid, str) or not udid:
        raise ValueError(f"available {name} on iOS {version} has no UDID")
    return udid


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtimes", required=True, type=Path)
    parser.add_argument("--devices", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--name", required=True)
    arguments = parser.parse_args()
    try:
        udid = resolve_udid(
            load_json(arguments.runtimes),
            load_json(arguments.devices),
            arguments.version,
            arguments.name,
        )
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(udid)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
