#!/usr/bin/env bash
# Exercise the real hygiene validator in a disposable tracked repository.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
git -C "$repository_root" archive HEAD | tar -x -C "$test_root"
# Exercise the working validator, including changes that are not committed yet.
cp "$repository_root/scripts/validate_open_source.sh" "$test_root/scripts/"
cp "$repository_root/scripts/ci_local.sh" "$test_root/scripts/"
cp "$repository_root/scripts/prepare_metal_toolchain_for_codeql.sh" "$test_root/scripts/"
cp "$repository_root/scripts/prepare_unsigned_archive.sh" "$test_root/scripts/"
mkdir -p "$test_root/.githooks"
cp "$repository_root/.githooks/pre-push" "$test_root/.githooks/"
chmod +x "$test_root/scripts/ci_local.sh" "$test_root/.githooks/pre-push"
git -C "$test_root" init -q

# Keep the fixture payload out of the test's own tracked source text.
retired_brand='Local AI'' Studio'
mkdir -p "$test_root/docs/superpowers/specs" "$test_root/docs/superpowers/plans"
printf '%s\n' "$retired_brand" > "$test_root/docs/superpowers/specs/branding-regression.md"
printf '%s\n' "$retired_brand" > "$test_root/docs/superpowers/plans/branding-regression.md"
# The upstream repository already tracks `Docs/`. Case-insensitive macOS
# filesystems therefore surface these archival paths with that casing.
mkdir -p "$test_root/Docs/superpowers/specs" "$test_root/Docs/superpowers/plans"
printf '%s\n' "$retired_brand" > "$test_root/Docs/superpowers/specs/branding-regression-uppercase.md"
printf '%s\n' "$retired_brand" > "$test_root/Docs/superpowers/plans/branding-regression-uppercase.md"
git -C "$test_root" add .

run_validator() {
  status=0
  bash "$test_root/scripts/validate_open_source.sh" > "$test_root/validation-output" 2>&1 || status=$?
}
fail() { cat "$test_root/validation-output" >&2; echo "FAIL: $*" >&2; exit 1; }

run_validator
[[ "$status" == 0 ]] || fail 'historical plan/spec branding must not block hygiene validation'
echo 'PASS: approved archival plan/spec branding is accepted'

chmod -x "$test_root/.githooks/pre-push"
run_validator
[[ "$status" != 0 ]] || fail 'non-executable tracked pre-push hook must fail validation'
grep -Fq '.githooks/pre-push' "$test_root/validation-output" || fail 'validator must identify the non-executable hook'
chmod +x "$test_root/.githooks/pre-push"
echo 'PASS: tracked pre-push hook must remain executable'

for relative_path in IOSLocalLLM/BrandingRegression.swift README.md docs/branding-regression.md; do
  cp "$test_root/$relative_path" "$test_root/original" 2>/dev/null || : > "$test_root/original"
  printf '%s\n' "$retired_brand" >> "$test_root/$relative_path"
  git -C "$test_root" add -- "$relative_path"
  run_validator
  [[ "$status" != 0 ]] || fail "retired branding escaped enforcement in $relative_path"
  grep -Fiq "$relative_path" "$test_root/validation-output" || fail 'validator must identify the offending product file'
  cp "$test_root/original" "$test_root/$relative_path"
  git -C "$test_root" add -- "$relative_path"
done
echo 'PASS: product source, README, and ordinary documentation branding still fails'

printf 'fixture\n' > "$test_root/docs/superpowers/specs/unsafe.gguf"
git -C "$test_root" add -f -- docs/superpowers/specs/unsafe.gguf
run_validator
[[ "$status" != 0 ]] || fail 'archival paths must retain publish-unsafe file enforcement'
grep -Fq 'publish-unsafe files are tracked' "$test_root/validation-output" || fail 'unsafe archive must fail the normal security gate'
echo 'PASS: archival paths retain publish-unsafe file enforcement'
echo 'All repository validator regression tests passed.'
