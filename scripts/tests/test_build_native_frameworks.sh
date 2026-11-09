#!/usr/bin/env bash

# Exercise orchestration in disposable repositories; never run Apple builders.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
real_git="$(command -v git)"
export REAL_GIT="$real_git"

fail() { echo "FAIL: $*" >&2; exit 1; }

fixture() {
  case_root="${test_root}/$1"
  mkdir -p "$case_root/scripts/native" "$case_root/ThirdParty/llama.cpp" "$case_root/bin"
  cp "$repository_root/scripts/build_native_frameworks.sh" "$case_root/scripts/"
  cp "$repository_root/.gitignore" "$case_root/"
  "$real_git" -C "$case_root" init -q
  export BUILD_LOG="$case_root/build.log" SUBMODULE_LOG="$case_root/submodule.log"
  export FORBID_WHISPER=0
  : >"$BUILD_LOG"
  : >"$SUBMODULE_LOG"
  cat >"$case_root/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${3:-}" == submodule ]]; then
  printf '%s\n' "${*:3}" >>"$SUBMODULE_LOG"
  if [[ "$FORBID_WHISPER" == 1 && "${*:3}" != 'submodule update --init --recursive -- ThirdParty/llama.cpp' ]]; then
    echo 'unexpected whisper submodule access' >&2
    exit 1
  fi
else
  exec "$REAL_GIT" "$@"
fi
STUB
  cat >"$case_root/bin/du" <<'STUB'
#!/usr/bin/env bash
echo disk >>"$BUILD_LOG"
echo '1M native build fixture'
STUB
  cat >"$case_root/ThirdParty/llama.cpp/build-xcframework.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# IOS_ONLY:-0 (the tracked patch has already been applied)
[[ "${IOS_ONLY:-0}" == 1 ]]
echo llama >>"$BUILD_LOG"
mkdir -p build-apple/llama.xcframework
echo generated >build-apple/llama.xcframework/Info.plist
STUB
  cat >"$case_root/scripts/native/build_whisper_ios.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$FORBID_WHISPER" == 0 ]]
echo whisper >>"$BUILD_LOG"
cd "$(dirname "$0")/../.."
mkdir -p ThirdParty/whisper.cpp/build-apple/whisper.xcframework
echo generated >ThirdParty/whisper.cpp/build-apple/whisper.xcframework/Info.plist
STUB
  cat >"$case_root/scripts/native/build_catalyst_slice.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$FORBID_WHISPER" == 0 || "$1" != whisper ]]
echo "catalyst $1" >>"$BUILD_LOG"
STUB
  chmod +x "$case_root/bin/"* "$case_root/ThirdParty/llama.cpp/build-xcframework.sh" "$case_root/scripts/native/"*.sh
}

run_build() {
  status=0
  PATH="$case_root/bin:$PATH" bash "$case_root/scripts/build_native_frameworks.sh" "$@" >"$case_root/output" 2>&1 || status=$?
}

assert_success() {
  [[ "$status" == 0 ]] || { cat "$case_root/output" >&2; fail "$*: expected exit 0, got $status"; }
}

assert_log() {
  [[ "$(cat "$BUILD_LOG")" == "$1" ]] || fail "unexpected build sequence: $(cat "$BUILD_LOG")"
}

assert_ignored() {
  local artifact="$1"
  [[ -f "$case_root/$artifact" ]] || fail "missing generated artifact: $artifact"
  "$real_git" -C "$case_root" check-ignore -q "$artifact" || fail "generated framework is not ignored"
  [[ -z "$("$real_git" -C "$case_root" ls-files -- "$artifact")" ]] || fail "generated framework is tracked"
  [[ -z "$("$real_git" -C "$case_root" ls-files --others --exclude-standard -- "$artifact")" ]] || fail "framework would be staged by git add"
}

# Dropping component selection must fail when whisper is uninitialized.
fixture llama-only
export FORBID_WHISPER=1
run_build --llama-only
assert_success '--llama-only without whisper'
assert_log $'disk\nllama\ndisk'
assert_ignored ThirdParty/llama.cpp/build-apple/llama.xcframework/Info.plist
grep -qi 'before' "$case_root/output" || fail 'missing before-build disk diagnostic'
grep -qi 'after' "$case_root/output" || fail 'missing after-build disk diagnostic'
echo 'PASS: llama-only skips whisper and reports disk usage; generated framework stays ignored'

# A pre-existing whisper artifact must not block a llama-only build.
fixture stale-whisper
export FORBID_WHISPER=1
mkdir -p "$case_root/ThirdParty/whisper.cpp/build-apple/whisper.xcframework"
run_build --llama-only
assert_success 'llama-only with pre-existing whisper output'
assert_log $'disk\nllama\ndisk'
echo 'PASS: llama-only skips whisper artifact checks'

for order in llama-first catalyst-first; do
  fixture "$order"
  export FORBID_WHISPER=1
  if [[ "$order" == llama-first ]]; then
    run_build --llama-only --with-catalyst
  else
    run_build --with-catalyst --llama-only
  fi
  assert_success "$order"
  assert_log $'disk\nllama\ncatalyst llama\ndisk'
done
echo 'PASS: Catalyst and llama-only flags work in either order'

for mode in default catalyst; do
  fixture "$mode"
  if [[ "$mode" == default ]]; then run_build; else run_build --with-catalyst; fi
  assert_success "$mode"
  [[ "$(cat "$SUBMODULE_LOG")" == 'submodule update --init --recursive' ]] || fail 'upstream submodule behavior changed'
  if [[ "$mode" == default ]]; then
    assert_log $'disk\nllama\nwhisper\ndisk'
  else
    assert_log $'disk\nllama\nwhisper\ncatalyst llama\ncatalyst whisper\ndisk'
  fi
  assert_ignored ThirdParty/llama.cpp/build-apple/llama.xcframework/Info.plist
  assert_ignored ThirdParty/whisper.cpp/build-apple/whisper.xcframework/Info.plist
done
echo 'PASS: upstream default and Catalyst builds select both components'

for mode in help help-last; do
  fixture "$mode"
  rm -rf "$case_root/ThirdParty"
  if [[ "$mode" == help ]]; then run_build --help; else run_build --with-catalyst --llama-only --help; fi
  assert_success "$mode"
  grep -q -- '--llama-only' "$case_root/output" || fail 'help omits llama-only usage'
  assert_log ''
  [[ ! -s "$SUBMODULE_LOG" ]] || fail 'help initialized submodules'
done
echo 'PASS: help exits before submodule access or build checks'

for mode in unknown trailing positional help-unknown; do
  fixture "$mode"
  case "$mode" in
    unknown) run_build --unknown ;;
    trailing) run_build --with-catalyst --unknown ;;
    positional) run_build --llama-only whisper ;;
    help-unknown) run_build --help --unknown ;;
  esac
  [[ "$status" == 64 ]] || fail "$mode: expected exit 64, got $status"
  assert_log ''
  [[ ! -s "$SUBMODULE_LOG" ]] || fail 'invalid flags initialized submodules'
done
echo 'PASS: unknown flags and positional arguments return 64 without side effects'

fixture stale-llama
mkdir -p "$case_root/ThirdParty/llama.cpp/build-apple/llama.xcframework"
run_build --llama-only
[[ "$status" != 0 ]] || fail 'existing llama output must be refused'
[[ "$(cat "$BUILD_LOG")" != *llama* ]] || fail 'builder ran despite existing llama output'
echo 'PASS: existing llama framework is still protected'

echo 'All native framework regression tests passed.'
