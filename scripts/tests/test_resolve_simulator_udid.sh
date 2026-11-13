#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
resolver="$repository_root/scripts/resolve_simulator_udid.py"
temporary="$(mktemp -d)"
trap 'find "$temporary" -type f -delete; rmdir "$temporary"' EXIT

write_valid_runtimes() {
  cat > "$temporary/runtimes.json" <<'JSON'
{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","version":"26.0.1","isAvailable":true},{"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-26-0","version":"26.0.1","isAvailable":true}]}
JSON
}

write_valid_devices() {
  cat > "$temporary/devices.json" <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"name":"iPhone 17 Pro","udid":"PINNED-UDID","isAvailable":true}]}}
JSON
}

write_valid_runtimes
write_valid_devices
output="$(python3 "$resolver" --runtimes "$temporary/runtimes.json" --devices "$temporary/devices.json" --version 26.0.1 --name 'iPhone 17 Pro')"
[[ "$output" == "PINNED-UDID" ]]
echo "PASS: resolver uses the runtime-reported identifier instead of guessing its format"

cat > "$temporary/runtimes.json" <<'JSON'
{"runtimes":[]}
JSON
if python3 "$resolver" --runtimes "$temporary/runtimes.json" --devices "$temporary/devices.json" --version 26.0.1 --name 'iPhone 17 Pro' >/dev/null 2>&1; then
  echo "FAIL: resolver accepted a missing exact runtime" >&2
  exit 1
fi
echo "PASS: resolver rejects a missing exact runtime"

cat > "$temporary/runtimes.json" <<'JSON'
{"runtimes":[{"identifier":"runtime-a","version":"26.0.1","isAvailable":true},{"identifier":"runtime-b","version":"26.0.1","isAvailable":true}]}
JSON
if python3 "$resolver" --runtimes "$temporary/runtimes.json" --devices "$temporary/devices.json" --version 26.0.1 --name 'iPhone 17 Pro' >/dev/null 2>&1; then
  echo "FAIL: resolver accepted ambiguous exact runtimes" >&2
  exit 1
fi
echo "PASS: resolver rejects ambiguous exact runtimes"

write_valid_runtimes
cat > "$temporary/devices.json" <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[]}}
JSON
if python3 "$resolver" --runtimes "$temporary/runtimes.json" --devices "$temporary/devices.json" --version 26.0.1 --name 'iPhone 17 Pro' >/dev/null 2>&1; then
  echo "FAIL: resolver accepted a missing pinned device" >&2
  exit 1
fi
echo "PASS: resolver rejects a missing pinned device"

cat > "$temporary/devices.json" <<'JSON'
{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-0":[{"name":"iPhone 17 Pro","udid":"A","isAvailable":true},{"name":"iPhone 17 Pro","udid":"B","isAvailable":true}]}}
JSON
if python3 "$resolver" --runtimes "$temporary/runtimes.json" --devices "$temporary/devices.json" --version 26.0.1 --name 'iPhone 17 Pro' >/dev/null 2>&1; then
  echo "FAIL: resolver accepted ambiguous pinned devices" >&2
  exit 1
fi
echo "PASS: resolver rejects ambiguous pinned devices"
