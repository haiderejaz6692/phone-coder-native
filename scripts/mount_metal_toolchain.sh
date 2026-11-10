#!/usr/bin/env bash
# Give CodeQL's traced process tree a stable, job-wide Metal toolchain mount.
# Xcode 26 normally exposes this optional component through a cryptex mount that
# github/codeql-action#3978 can make inaccessible after tracer initialization.
set -euo pipefail

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
if [[ "$toolchain_identifier" != "com.apple.dt.toolchain.Metal.32023" ]]; then
  echo "error: unexpected Metal toolchain identifier '$toolchain_identifier'" >&2
  exit 1
fi
if [[ -z "$asset_path" || "$asset_path" != /* || ! -d "$asset_path/Restore" ]]; then
  echo "error: MetalToolchain returned an invalid Asset Path: $asset_path" >&2
  exit 1
fi

shopt -s nullglob
images=("$asset_path"/Restore/*.dmg)
shopt -u nullglob
if [[ ${#images[@]} -ne 1 ]]; then
  echo "error: expected exactly one MetalToolchain disk image, found ${#images[@]}" >&2
  exit 1
fi
if [[ ! -f "${images[0]}" || -L "${images[0]}" ]]; then
  echo "error: MetalToolchain disk image must be one regular, non-symlink file" >&2
  exit 1
fi

# Do not trust the ordinary cryptex mount alone: CodeQL's macOS tracer loses
# access to it. Attaching the reviewed component image exposes the same signed
# Apple toolchain through a normal volume that remains visible while tracing.
hdiutil attach "${images[0]}" -readonly -nobrowse
xcrun --find metal
xcrun metal -v
