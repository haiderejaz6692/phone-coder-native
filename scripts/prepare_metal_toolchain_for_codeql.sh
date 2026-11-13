#!/usr/bin/env bash
# Make Xcode 26's optional Metal compiler independent of its private cryptex
# mount before CodeQL starts tracing. The tracer can hide that mount, so copy
# only Apple's signed Metal payload into the ephemeral runner's default Xcode
# toolchain. This mirrors the approach used by Brave's hermetic Xcode builder.
set -euo pipefail

expected_identifier="com.apple.dt.toolchain.Metal.32023"
component_asset_root="${METAL_COMPONENT_ASSET_ROOT:-/System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain}"
mobile_asset_mount_root="${METAL_MOBILE_ASSET_MOUNT_ROOT:-/var/run/com.apple.security.cryptexd/mnt}"

component_details="$(xcodebuild -showComponent MetalToolchain)"

field() {
  local name="$1"
  printf '%s\n' "$component_details" |
    awk -F': ' -v expected="$name" '$1 == expected { print substr($0, length($1) + 3); exit }'
}

status="$(field 'Status')"
asset_path="$(field 'Asset Path')"
toolchain_identifier="$(field 'Toolchain Identifier')"

if [[ "$status" != "installed" ]]; then
  echo "error: MetalToolchain status is '$status', expected 'installed'" >&2
  exit 1
fi
if [[ "$toolchain_identifier" != "$expected_identifier" ]]; then
  echo "error: unexpected Metal toolchain identifier '$toolchain_identifier'" >&2
  exit 1
fi
if [[ -z "$asset_path" || "$asset_path" != "$component_asset_root"/* ||
      ! -d "$asset_path/Restore" || -L "$asset_path/Restore" ]]; then
  echo "error: MetalToolchain returned an invalid Asset Path: $asset_path" >&2
  exit 1
fi

shopt -s nullglob
images=("$asset_path"/Restore/*.dmg)
shopt -u nullglob
if [[ ${#images[@]} -ne 1 || ! -f "${images[0]:-}" || -L "${images[0]:-}" ]]; then
  echo "error: expected exactly one regular, non-symlink MetalToolchain disk image" >&2
  exit 1
fi

metal_bin="$(xcrun --find metal)"
if [[ -z "$metal_bin" || "$metal_bin" == *$'\n'* ||
      "$metal_bin" != "$mobile_asset_mount_root"/com.apple.MobileAsset.MetalToolchain-v*/Metal.xctoolchain/usr/bin/metal ]]; then
  echo "error: resolved Metal compiler is outside the downloaded Apple MobileAsset: $metal_bin" >&2
  exit 1
fi
metal_toolchain="${metal_bin%/usr/bin/metal}"

source_metal="$metal_toolchain/usr/metal"
source_bin="$metal_toolchain/usr/bin"
drivers=(air-lld metal metallib)
if [[ ! -d "$source_metal" || -L "$source_metal" ]]; then
  echo "error: downloaded Metal toolchain has an invalid usr/metal tree" >&2
  exit 1
fi
for driver in "${drivers[@]}"; do
  source_driver="$source_bin/$driver"
  if [[ ! -f "$source_driver" || ! -x "$source_driver" ]]; then
    echo "error: downloaded Metal toolchain is missing executable $driver" >&2
    exit 1
  fi
  codesign --verify --strict "$source_driver"
done
xcrun metal -v

if [[ -z "${DEVELOPER_DIR:-}" || "$DEVELOPER_DIR" != /* ]]; then
  echo "error: DEVELOPER_DIR must identify an absolute Xcode developer directory" >&2
  exit 1
fi
destination_usr="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr"
if [[ ! -d "$destination_usr" || -L "$destination_usr" ||
      ! -d "$destination_usr/bin" || -L "$destination_usr/bin" ||
      ( -e "$destination_usr/metal" &&
        ( ! -d "$destination_usr/metal" || -L "$destination_usr/metal" ) ) ]]; then
  echo "error: invalid XcodeDefault toolchain destination: $destination_usr" >&2
  exit 1
fi

# The GitHub runner is disposable. Preserve modes, symlinks, and signatures;
# mirror only usr/metal, then replace only the three Metal driver binaries.
sudo rsync --archive --delete "$source_metal/" "$destination_usr/metal/"
sudo rsync --archive \
  "$source_bin/air-lld" \
  "$source_bin/metal" \
  "$source_bin/metallib" \
  "$destination_usr/bin/"

for driver in "${drivers[@]}"; do
  codesign --verify --strict "$destination_usr/bin/$driver"
done
"$destination_usr/bin/metal" -v
