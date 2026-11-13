#!/usr/bin/env bash
# Run every Phone Coder CI check that this checkout can prove without Xcode or
# GitHub-hosted services. This script never installs dependencies or pushes.
set -euo pipefail

usage() {
  echo "usage: $0 [--base REF]" >&2
}

base_ref=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      if [[ $# -lt 2 || -z "$2" ]]; then
        usage
        exit 64
      fi
      base_ref="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if ! repository_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  echo "error: local CI gate must run inside a Git checkout" >&2
  exit 1
fi
cd "$repository_root"

if [[ -z "$(git branch --show-current)" ]]; then
  echo "error: local CI gate requires a branch; detached HEAD cannot be pushed safely" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1 ||
    ! python3 -c 'import yaml; raise SystemExit(yaml.__version__ != "6.0.3")' \
      >/dev/null 2>&1; then
  echo "error: Python 3 with PyYAML 6.0.3 is required" >&2
  echo "Create a virtual environment and install exactly: PyYAML==6.0.3" >&2
  exit 1
fi

if [[ -z "$base_ref" ]]; then
  for candidate in refs/remotes/origin/main refs/remotes/upstream/main refs/heads/main; do
    if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then
      base_ref="$candidate"
      break
    fi
  done
fi
if [[ -z "$base_ref" ]] ||
    ! requested_base="$(git rev-parse --verify "$base_ref^{commit}" 2>/dev/null)"; then
  echo "error: cannot resolve DCO base ref '${base_ref:-<automatic>}'" >&2
  echo "Fetch the base branch or pass --base REF." >&2
  exit 1
fi
head_sha="$(git rev-parse --verify 'HEAD^{commit}')"
if ! base_sha="$(git merge-base "$requested_base" "$head_sha")" || [[ -z "$base_sha" ]]; then
  echo "error: DCO base '$base_ref' has no merge base with HEAD" >&2
  exit 1
fi

submodule_status="$(git submodule status --recursive)"
if printf '%s\n' "$submodule_status" | grep -Eq '^[+-U]'; then
  echo "error: submodules are uninitialized, conflicted, or not at their pinned commits" >&2
  printf '%s\n' "$submodule_status" >&2
  exit 1
fi

dirty_submodules="$(git submodule foreach --quiet --recursive '
  if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
    printf "%s\n" "$displaypath"
  fi
')"
if [[ -n "$dirty_submodules" ]]; then
  echo "error: submodule worktrees must be clean before running the local gate" >&2
  printf '%s\n' "$dirty_submodules" >&2
  exit 1
fi

snapshot_checkout() {
  python3 - <<'PY'
import hashlib
import os
import stat
import subprocess

digest = hashlib.sha256()

def add(value):
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)

add(subprocess.check_output(["git", "rev-parse", "HEAD^{commit}"]))
add(subprocess.check_output([
    "git", "status", "--porcelain=v1", "-z", "--untracked-files=all",
]))
add(subprocess.check_output([
    "git", "diff", "--cached", "--binary", "--no-ext-diff", "HEAD", "--",
]))

paths = subprocess.check_output([
    "git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
]).split(b"\0")
for path in sorted(value for value in paths if value):
    add(path)
    try:
        metadata = os.lstat(path)
    except FileNotFoundError:
        add(b"missing")
        continue
    add(str(stat.S_IMODE(metadata.st_mode)).encode("ascii"))
    if stat.S_ISREG(metadata.st_mode):
        add(b"file")
        file_digest = hashlib.sha256()
        with open(path, "rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                file_digest.update(chunk)
        add(file_digest.digest())
    elif stat.S_ISLNK(metadata.st_mode):
        add(b"symlink")
        add(os.readlink(path))
    elif stat.S_ISDIR(metadata.st_mode):
        # Gitlinks are covered by the clean/pinned submodule checks above.
        add(b"directory")
    else:
        add(b"special")

print(digest.hexdigest())
PY
}

status_before="$(git status --porcelain=v1 --untracked-files=all)"
snapshot_before="$(snapshot_checkout)"
passed=0

run_step() {
  local name="$1"
  shift
  printf '\n==> %s\n' "$name"
  if "$@"; then
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$name"
  else
    local status=$?
    printf 'FAILED: %s (exit %s)\n' "$name" "$status" >&2
    exit "$status"
  fi
}

run_step "committed-range whitespace" git diff --check "$base_sha...$head_sha"
run_step "unstaged whitespace" git diff --check
run_step "staged whitespace" git diff --cached --check
run_step "repository hygiene" bash scripts/validate_open_source.sh
run_step "workflow contract" bash scripts/validate_phone_coder_workflows.sh
run_step "repository validator regressions" bash scripts/tests/test_validate_open_source.sh
run_step "workflow mutation regressions" bash scripts/tests/test_validate_phone_coder_workflows.sh
run_step "native framework orchestration regressions" bash scripts/tests/test_build_native_frameworks.sh
run_step "CodeQL Metal preparation regressions" \
  bash scripts/tests/test_prepare_metal_toolchain_for_codeql.sh
run_step "simulator resolver regressions" bash scripts/tests/test_resolve_simulator_udid.sh
run_step "bounded command runner regressions" bash scripts/tests/test_run_with_timeout.sh
run_step "unsigned archive preparation regressions" \
  bash scripts/tests/test_prepare_unsigned_archive.sh
run_step "unsigned IPA security regressions" bash scripts/tests/test_package_unsigned_ipa.sh
run_step "DCO sign-offs" bash scripts/validate_dco.sh "$base_sha" "$head_sha"

status_after="$(git status --porcelain=v1 --untracked-files=all)"
snapshot_after="$(snapshot_checkout)"
if [[ "$snapshot_after" != "$snapshot_before" ]]; then
  echo "error: local checks changed the worktree or HEAD" >&2
  echo "Before:" >&2
  printf '%s\n' "$status_before" >&2
  echo "After:" >&2
  printf '%s\n' "$status_after" >&2
  exit 1
fi

printf '\nLOCAL CI GATE: PASS (%s checks)\n' "$passed"
echo "DCO range: $base_sha..$head_sha"
echo "REMOTE REQUIRED: macOS/Xcode and GitHub service checks were not executed"
echo "  - VoiceAgentOrb on macOS 15"
echo "  - iOS Simulator tests and unsigned Xcode archive"
echo "  - Swift CodeQL under the macOS tracer"
echo "  - GitHub Dependency Review, OpenSSF upload, and attestations"
