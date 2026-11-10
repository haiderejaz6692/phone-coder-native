#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
asset_root="$test_root/asset/AssetData"
mkdir -p "$fake_bin" "$asset_root/Restore"
: > "$asset_root/Restore/MetalToolchain.dmg"

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-showComponent MetalToolchain" ]]
printf 'Asset Path: %s\nBuild Version: 17A400\nStatus: %s\nToolchain Identifier: com.apple.dt.toolchain.Metal.32023\n' \
  "$FAKE_ASSET_PATH" "${FAKE_COMPONENT_STATUS:-installed}"
EOF

cat > "$fake_bin/hdiutil" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALL_LOG"
[[ "${FAKE_ATTACH_FAILURE:-0}" == 0 ]]
EOF

cat > "$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >> "$FAKE_CALL_LOG"
if [[ "$1" == "--find" ]]; then
  printf '/Volumes/MetalToolchainCryptex/Metal.xctoolchain/usr/bin/metal\n'
else
  printf 'Apple metal version fixture\n'
fi
EOF
chmod +x "$fake_bin"/*

export PATH="$fake_bin:$PATH"
export FAKE_ASSET_PATH="$asset_root"
export FAKE_CALL_LOG="$test_root/calls"

bash "$repository_root/scripts/mount_metal_toolchain.sh"
grep -Fqx "attach $asset_root/Restore/MetalToolchain.dmg -readonly -nobrowse" "$FAKE_CALL_LOG"
grep -Fqx 'xcrun --find metal' "$FAKE_CALL_LOG"
grep -Fqx 'xcrun metal -v' "$FAKE_CALL_LOG"
echo 'PASS: mounts the one installed component image and verifies both lookup and execution'

if FAKE_COMPONENT_STATUS=uninstalled bash "$repository_root/scripts/mount_metal_toolchain.sh" \
    >"$test_root/uninstalled.out" 2>&1; then
  echo 'FAIL: accepted an uninstalled Metal component' >&2
  exit 1
fi
grep -Fq "MetalToolchain status is 'uninstalled'" "$test_root/uninstalled.out"
echo 'PASS: rejects an uninstalled component'

: > "$asset_root/Restore/OtherMetalToolchain.dmg"
if bash "$repository_root/scripts/mount_metal_toolchain.sh" >"$test_root/multiple.out" 2>&1; then
  echo 'FAIL: accepted ambiguous Metal component images' >&2
  exit 1
fi
grep -Fq 'expected exactly one MetalToolchain disk image, found 2' "$test_root/multiple.out"
rm "$asset_root/Restore/OtherMetalToolchain.dmg"
echo 'PASS: rejects ambiguous component images'

if FAKE_ATTACH_FAILURE=1 bash "$repository_root/scripts/mount_metal_toolchain.sh" \
    >"$test_root/attach-failure.out" 2>&1; then
  echo 'FAIL: swallowed a disk-image mount failure' >&2
  exit 1
fi
echo 'PASS: propagates mount failures'

echo 'All Metal toolchain mount helper tests passed.'
