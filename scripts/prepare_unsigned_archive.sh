#!/usr/bin/env bash
# Normalize only Xcode-owned Swift back-deployment libraries before unsigned packaging.
set -euo pipefail

if [[ "$#" != 1 ]]; then
  echo "usage: $0 <PhoneCoder.xcarchive>" >&2
  exit 64
fi
if [[ "$(uname -s)" != Darwin && "${PHONE_CODER_PORTABLE_TEST:-0}" != 1 ]]; then
  echo 'error: unsigned archive preparation requires macOS; PHONE_CODER_PORTABLE_TEST=1 is for fake-archive tests only' >&2
  exit 1
fi

archive="$1"
if [[ ! -d "$archive" || -L "$archive" ]]; then
  echo 'error: archive must be a real directory, not a symlink' >&2
  exit 1
fi
app="$archive/Products/Applications/Phone Coder.app"
if [[ ! -d "$app" || -L "$archive/Products" || -L "$archive/Products/Applications" || -L "$app" ]]; then
  echo 'error: archive must contain exactly Phone Coder.app at Products/Applications' >&2
  exit 1
fi
shopt -s nullglob dotglob
archive_app_entries=("$archive/Products/Applications"/*)
if [[ "${#archive_app_entries[@]}" != 1 || "${archive_app_entries[0]}" != "$app" ]]; then
  echo 'error: archive must contain exactly Phone Coder.app at Products/Applications' >&2
  exit 1
fi

embedded="$app/Frameworks/libswiftCompatibilitySpan.dylib"
if [[ ! -e "$embedded" && ! -L "$embedded" ]]; then
  echo 'No Swift compatibility signature required normalization.'
  exit 0
fi
if [[ ! -f "$embedded" || -L "$embedded" ]]; then
  echo 'error: embedded Swift compatibility library must be a regular file' >&2
  exit 1
fi

swiftc="$(xcrun --find swiftc)"
if [[ ! -x "$swiftc" && "${PHONE_CODER_PORTABLE_TEST:-0}" != 1 ]]; then
  echo 'error: selected Xcode toolchain has no executable swiftc' >&2
  exit 1
fi
toolchain_usr="$(cd "$(dirname "$swiftc")/.." && pwd -P)"
toolchain_lib="$toolchain_usr/lib"
if [[ ! -d "$toolchain_lib" ]]; then
  echo 'error: selected Xcode toolchain has no Swift library directory' >&2
  exit 1
fi

matching_sources=()
while IFS= read -r -d '' candidate; do
  if cmp -s "$candidate" "$embedded"; then
    matching_sources+=("$candidate")
  fi
done < <(find "$toolchain_lib" -type f -path '*/iphoneos/libswiftCompatibilitySpan.dylib' -print0)
if [[ "${#matching_sources[@]}" != 1 ]]; then
  echo 'error: embedded Swift compatibility library does not match the selected Xcode toolchain' >&2
  exit 1
fi

# Xcode copies this signed back-deployment shim even when app signing is disabled.
# Removing only this proven toolchain copy makes the later all-member verifier's
# zero-signature invariant truthful without accepting or mutating arbitrary code.
codesign --remove-signature "$embedded"
if codesign --verify --strict "$embedded" >/dev/null 2>&1; then
  echo 'error: Swift compatibility library remained signed after normalization' >&2
  exit 1
fi

echo "Prepared unsigned archive: removed the Xcode toolchain signature from ${embedded#"$archive"/}."
