#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fake_bin="$test_root/bin"
asset_root="$test_root/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain/asset/AssetData"
source_toolchain="$test_root/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.1.324.0.fixture/Metal.xctoolchain"
developer_dir="$test_root/Applications/Xcode_26.0.1.app/Contents/Developer"
destination_usr="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr"
mkdir -p "$fake_bin" "$asset_root/Restore" "$source_toolchain/usr/metal/current/bin" \
  "$source_toolchain/usr/bin" "$destination_usr/bin"
: > "$asset_root/Restore/MetalToolchain.dmg"

for tool in air-lld metal metallib; do
  cat > "$source_toolchain/usr/bin/$tool" <<EOF
#!/usr/bin/env bash
printf 'Apple $tool fixture\\n'
EOF
  chmod +x "$source_toolchain/usr/bin/$tool"
done
printf 'metal-library-data\n' > "$source_toolchain/usr/metal/current/bin/metal-library-data"

cat > "$fake_bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "-showComponent MetalToolchain" ]]
printf 'Asset Path: %s\nBuild Version: 17A400\nStatus: %s\nToolchain Identifier: %s\n' \
  "$FAKE_ASSET_PATH" "${FAKE_COMPONENT_STATUS:-installed}" \
  "${FAKE_TOOLCHAIN_IDENTIFIER:-com.apple.dt.toolchain.Metal.32023}"
EOF

cat > "$fake_bin/xcrun" <<'EOF'
#!/usr/bin/env bash
printf 'xcrun %s\n' "$*" >> "$FAKE_CALL_LOG"
if [[ "$1" == "--find" ]]; then
  printf '%s\n' "$FAKE_SOURCE_TOOLCHAIN/usr/bin/metal"
else
  printf 'Apple metal version fixture\n'
fi
EOF

cat > "$fake_bin/codesign" <<'EOF'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >> "$FAKE_CALL_LOG"
EOF

cat > "$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$FAKE_CALL_LOG"
"$@"
EOF

cat > "$fake_bin/rsync" <<'EOF'
#!/usr/bin/env bash
printf 'rsync %s\n' "$*" >> "$FAKE_CALL_LOG"
args=("$@")
sources=()
last_index=$((${#args[@]} - 1))
destination="${args[$last_index]}"
for ((index = 0; index < ${#args[@]} - 1; index++)); do
  [[ "${args[index]}" == -* ]] && continue
  sources+=("${args[index]}")
done
for source in "${sources[@]}"; do
  if [[ "$source" == */ ]]; then
    mkdir -p "$destination"
    cp -a "${source}." "$destination"
  else
    cp -a "$source" "$destination"
  fi
done
EOF
chmod +x "$fake_bin"/*

export PATH="$fake_bin:$PATH"
export DEVELOPER_DIR="$developer_dir"
export FAKE_ASSET_PATH="$asset_root"
export FAKE_SOURCE_TOOLCHAIN="$source_toolchain"
export FAKE_CALL_LOG="$test_root/calls"
export METAL_COMPONENT_ASSET_ROOT="$test_root/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain"
export METAL_MOBILE_ASSET_MOUNT_ROOT="$test_root/var/run/com.apple.security.cryptexd/mnt"

bash "$repository_root/scripts/prepare_metal_toolchain_for_codeql.sh"
grep -Fqx 'xcrun --find metal' "$FAKE_CALL_LOG"
grep -Fqx 'xcrun metal -v' "$FAKE_CALL_LOG"
grep -Fqx "codesign --verify --strict $source_toolchain/usr/bin/air-lld" "$FAKE_CALL_LOG"
grep -Fqx "codesign --verify --strict $source_toolchain/usr/bin/metal" "$FAKE_CALL_LOG"
grep -Fqx "codesign --verify --strict $source_toolchain/usr/bin/metallib" "$FAKE_CALL_LOG"
grep -Fqx "sudo rsync --archive --delete $source_toolchain/usr/metal/ $destination_usr/metal/" "$FAKE_CALL_LOG"
grep -Fqx "sudo rsync --archive $source_toolchain/usr/bin/air-lld $source_toolchain/usr/bin/metal $source_toolchain/usr/bin/metallib $destination_usr/bin/" "$FAKE_CALL_LOG"
grep -Fqx "codesign --verify --strict $destination_usr/bin/metal" "$FAKE_CALL_LOG"
grep -Fq 'metal-library-data' "$destination_usr/metal/current/bin/metal-library-data"
[[ "$($destination_usr/bin/metal -v)" == 'Apple metal fixture' ]]
echo 'PASS: grafts only the signed Metal tree and drivers into XcodeDefault'

if FAKE_COMPONENT_STATUS=uninstalled bash "$repository_root/scripts/prepare_metal_toolchain_for_codeql.sh" \
    >"$test_root/uninstalled.out" 2>&1; then
  echo 'FAIL: accepted an uninstalled Metal component' >&2
  exit 1
fi
grep -Fq "MetalToolchain status is 'uninstalled'" "$test_root/uninstalled.out"
echo 'PASS: rejects an uninstalled component'

if FAKE_TOOLCHAIN_IDENTIFIER=com.example.unreviewed bash \
    "$repository_root/scripts/prepare_metal_toolchain_for_codeql.sh" >"$test_root/identifier.out" 2>&1; then
  echo 'FAIL: accepted an unreviewed Metal toolchain identifier' >&2
  exit 1
fi
grep -Fq "unexpected Metal toolchain identifier 'com.example.unreviewed'" "$test_root/identifier.out"
echo 'PASS: rejects an unreviewed toolchain identifier'

unsafe_source="$test_root/unreviewed/Metal.xctoolchain"
mkdir -p "$unsafe_source/usr/bin"
if FAKE_SOURCE_TOOLCHAIN="$unsafe_source" bash \
    "$repository_root/scripts/prepare_metal_toolchain_for_codeql.sh" >"$test_root/source.out" 2>&1; then
  echo 'FAIL: accepted a Metal toolchain outside the reviewed MobileAsset mount' >&2
  exit 1
fi
grep -Fq 'resolved Metal compiler is outside the downloaded Apple MobileAsset' "$test_root/source.out"
echo 'PASS: rejects a compiler outside the downloaded Apple MobileAsset mount'

missing_destination="$test_root/missing/Xcode.app/Contents/Developer"
if DEVELOPER_DIR="$missing_destination" bash \
    "$repository_root/scripts/prepare_metal_toolchain_for_codeql.sh" >"$test_root/destination.out" 2>&1; then
  echo 'FAIL: accepted a missing XcodeDefault destination' >&2
  exit 1
fi
grep -Fq 'invalid XcodeDefault toolchain destination' "$test_root/destination.out"
echo 'PASS: rejects an invalid destination instead of creating arbitrary paths'

echo 'All CodeQL Metal toolchain preparation tests passed.'
