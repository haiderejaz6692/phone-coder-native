#!/usr/bin/env bash

# Exercise preparation with fake archives and toolchain files; never call Apple's codesign.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
prepare="$repository_root/scripts/prepare_unsigned_archive.sh"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

make_fixture() {
  case_root="$test_root/$1"
  archive="$case_root/PhoneCoder.xcarchive"
  app_frameworks="$archive/Products/Applications/Phone Coder.app/Frameworks"
  toolchain_usr="$case_root/toolchain/usr"
  toolchain_library="$toolchain_usr/lib/swift-6.2/iphoneos/libswiftCompatibilitySpan.dylib"
  embedded_library="$app_frameworks/libswiftCompatibilitySpan.dylib"
  mkdir -p "$app_frameworks" "$(dirname "$toolchain_library")" "$toolchain_usr/bin" "$case_root/bin"
  printf 'signed toolchain bytes\n' >"$toolchain_library"
  cp "$toolchain_library" "$embedded_library"
  : >"$case_root/codesign.log"
  cat >"$case_root/bin/xcrun" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$*" == '--find swiftc' ]]
printf '%s\n' '$toolchain_usr/bin/swiftc'
EOF
  cat >"$case_root/bin/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CODESIGN_LOG"
if [[ "$1" == '--remove-signature' && "$#" == 2 ]]; then
  printf 'unsigned bytes\n' >"$2"
  exit 0
fi
if [[ "$1" == '--verify' ]]; then
  exit 1
fi
exit 64
EOF
  chmod +x "$case_root/bin/xcrun" "$case_root/bin/codesign"
}

run_prepare() {
  status=0
  CODESIGN_LOG="$case_root/codesign.log" PATH="$case_root/bin:$PATH" \
    PHONE_CODER_PORTABLE_TEST=1 bash "$prepare" "$archive" \
    >"$case_root/output" 2>&1 || status=$?
}

make_fixture matching-toolchain-copy
run_prepare
[[ "$status" == 0 ]] || { cat "$case_root/output" >&2; fail 'matching toolchain copy was rejected'; }
[[ "$(cat "$embedded_library")" == 'unsigned bytes' ]] || fail 'embedded signature was not removed'
[[ "$(cat "$case_root/codesign.log")" == $'--remove-signature '"$embedded_library"$'\n--verify --strict '"$embedded_library" ]] ||
  fail "unexpected codesign operations: $(cat "$case_root/codesign.log")"
grep -q 'Prepared unsigned archive' "$case_root/output" || fail 'missing success diagnostic'
echo 'PASS: exact Xcode toolchain compatibility copy is normalized and verified unsigned'

make_fixture mismatched-copy
printf 'unreviewed injected bytes\n' >"$embedded_library"
run_prepare
[[ "$status" != 0 ]] || fail 'mismatched embedded library was accepted'
[[ ! -s "$case_root/codesign.log" ]] || fail 'mismatched library reached codesign'
grep -q 'does not match the selected Xcode toolchain' "$case_root/output" || fail 'missing provenance failure'
echo 'PASS: non-toolchain compatibility library fails closed before mutation'

make_fixture symlinked-copy
rm "$embedded_library"
ln -s "$toolchain_library" "$embedded_library"
run_prepare
[[ "$status" != 0 ]] || fail 'symlinked embedded library was accepted'
[[ ! -s "$case_root/codesign.log" ]] || fail 'symlinked library reached codesign'
echo 'PASS: symlinked compatibility library fails closed'

make_fixture absent-copy
rm "$embedded_library"
run_prepare
[[ "$status" == 0 ]] || { cat "$case_root/output" >&2; fail 'archive without compatibility library was rejected'; }
[[ ! -s "$case_root/codesign.log" ]] || fail 'codesign ran without a compatibility library'
grep -q 'No Swift compatibility signature required normalization' "$case_root/output" || fail 'missing no-op diagnostic'
echo 'PASS: archive without a back-deployment library remains a safe no-op'

make_fixture unexpected-archive-layout
mv "$archive/Products/Applications/Phone Coder.app" "$archive/Products/Applications/Other.app"
run_prepare
[[ "$status" != 0 ]] || fail 'unexpected app layout was accepted'
[[ ! -s "$case_root/codesign.log" ]] || fail 'invalid archive reached codesign'
echo 'PASS: preparation requires the exact Phone Coder archive layout'

echo 'All unsigned archive preparation regressions passed.'
