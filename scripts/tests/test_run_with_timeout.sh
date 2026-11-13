#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repository_root/scripts/run_with_timeout.py"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

if [[ ! -f "$runner" ]]; then
  echo "FAIL: missing bounded-command runner: $runner" >&2
  exit 1
fi

output="$(python3 "$runner" --timeout-seconds 5 -- bash -c 'printf bounded-output')"
[[ "$output" == bounded-output ]]
echo "PASS: bounded runner preserves child output and success"

status=0
python3 "$runner" --timeout-seconds 5 -- bash -c 'exit 23' || status=$?
[[ "$status" == 23 ]]
echo "PASS: bounded runner preserves child failure status"

status=0
python3 "$runner" --timeout-seconds 0.2 -- \
  bash -c 'trap '\''printf terminated > "$1"; exit 0'\'' TERM; sleep 30' _ \
  "$temporary/terminated" >"$temporary/timeout.out" 2>"$temporary/timeout.err" || status=$?
[[ "$status" == 124 ]]
[[ "$(cat "$temporary/terminated")" == terminated ]]
grep -Fq 'exceeded 0.2 seconds' "$temporary/timeout.err"
echo "PASS: bounded runner terminates the process group and reports timeout status"
