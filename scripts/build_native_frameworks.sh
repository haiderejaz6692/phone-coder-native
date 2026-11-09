#!/usr/bin/env bash

# Reproducibly build the native llama.cpp and whisper.cpp XCFrameworks from
# pinned submodules. Generated frameworks remain ignored by Git.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
include_catalyst=0
llama_only=0
show_help=0

usage() {
  echo "usage: $0 [--llama-only] [--with-catalyst] [--help]"
  echo "  --llama-only     Build llama.cpp only; do not initialize or check whisper.cpp"
  echo "  --with-catalyst  Add the Mac Catalyst slice to each selected framework"
  echo "  --help           Show this help without initializing or building anything"
}

for argument in "$@"; do
  case "$argument" in
    --llama-only) llama_only=1 ;;
    --with-catalyst) include_catalyst=1 ;;
    --help) show_help=1 ;;
    *)
      echo "error: unknown argument: $argument" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ "$show_help" == 1 ]]; then
  usage
  exit 0
fi

echo "==> Disk usage before native build"
du -sh "$repository_root"

if [[ "$llama_only" == 1 ]]; then
  git -C "$repository_root" submodule update --init --recursive -- ThirdParty/llama.cpp
else
  git -C "$repository_root" submodule update --init --recursive
fi

llama_root="${repository_root}/ThirdParty/llama.cpp"
llama_patch="${repository_root}/Patches/llama.cpp-ios-only-xcframework.patch"

if grep -q 'IOS_ONLY:-0' "${llama_root}/build-xcframework.sh"; then
  echo "==> llama.cpp iOS-only build support is already present"
elif git -C "$llama_root" apply --check "$llama_patch" >/dev/null 2>&1; then
  echo "==> Applying the tracked llama.cpp iOS-only build patch"
  git -C "$llama_root" apply "$llama_patch"
else
  echo "error: the llama.cpp build patch does not match the pinned submodule" >&2
  echo "       restore or inspect ThirdParty/llama.cpp/build-xcframework.sh" >&2
  exit 1
fi

if [[ -e "${llama_root}/build-apple/llama.xcframework" ]]; then
  echo "error: generated llama.xcframework already exists; remove it before rebuilding" >&2
  exit 1
fi
if [[ "$llama_only" == 0 && -e "${repository_root}/ThirdParty/whisper.cpp/build-apple/whisper.xcframework" ]]; then
  echo "error: generated whisper.xcframework already exists; remove it before rebuilding" >&2
  exit 1
fi

echo "==> Building llama.cpp iOS XCFramework"
(cd "$llama_root" && IOS_ONLY=1 ./build-xcframework.sh)

if [[ "$llama_only" == 0 ]]; then
  echo "==> Building whisper.cpp iOS XCFramework"
  "${repository_root}/scripts/native/build_whisper_ios.sh"
fi

if [[ "$include_catalyst" == 1 ]]; then
  "${repository_root}/scripts/native/build_catalyst_slice.sh" llama
  if [[ "$llama_only" == 0 ]]; then
    "${repository_root}/scripts/native/build_catalyst_slice.sh" whisper
  fi
fi

echo "==> Disk usage after native build"
du -sh "$repository_root"

echo "==> Native frameworks are ready"
