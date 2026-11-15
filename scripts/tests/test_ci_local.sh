#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate_source="$repository_root/scripts/ci_local.sh"
hook_source="$repository_root/.githooks/pre-push"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

if [[ ! -x "$gate_source" ]]; then
  echo "FAIL: missing executable local gate: $gate_source" >&2
  exit 1
fi
if [[ ! -x "$hook_source" ]]; then
  echo "FAIL: missing executable pre-push hook: $hook_source" >&2
  exit 1
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_fixture() {
  local name="$1"
  local fixture="$test_root/$name/repository"
  mkdir -p "$fixture/scripts/tests" "$fixture/.githooks"
  cp "$gate_source" "$fixture/scripts/ci_local.sh"
  cp "$hook_source" "$fixture/.githooks/pre-push"

  local relative_path
  for relative_path in \
    scripts/validate_open_source.sh \
    scripts/validate_phone_coder_workflows.sh \
    scripts/tests/test_validate_open_source.sh \
    scripts/tests/test_validate_phone_coder_workflows.sh \
    scripts/tests/test_build_native_frameworks.sh \
    scripts/tests/test_prepare_metal_toolchain_for_codeql.sh \
    scripts/tests/test_resolve_simulator_udid.sh \
    scripts/tests/test_run_with_timeout.sh \
    scripts/tests/test_prepare_unsigned_archive.sh \
    scripts/tests/test_package_unsigned_ipa.sh \
    scripts/validate_dco.sh; do
    mkdir -p "$fixture/$(dirname "$relative_path")"
    cp "$test_root/stub-check.sh" "$fixture/$relative_path"
  done

  printf 'baseline\n' > "$fixture/tracked.txt"
  git -C "$fixture" init -q
  git -C "$fixture" config user.name 'Local Gate Fixture'
  git -C "$fixture" config user.email 'local-gate@example.test'
  git -C "$fixture" add .
  git -C "$fixture" commit -q -m $'test: fixture base\n\nSigned-off-by: Local Gate Fixture <local-gate@example.test>'
  local base_sha
  base_sha="$(git -C "$fixture" rev-parse HEAD)"
  git -C "$fixture" update-ref refs/remotes/origin/main "$base_sha"
  printf 'feature\n' > "$fixture/feature.txt"
  git -C "$fixture" add feature.txt
  git -C "$fixture" commit -q -m $'test: fixture feature\n\nSigned-off-by: Local Gate Fixture <local-gate@example.test>'
  printf '%s\n' "$fixture"
}

cat > "$test_root/stub-check.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0")"
printf '%s' "$name" >> "$FAKE_CALL_LOG"
if [[ $# -gt 0 ]]; then
  printf '\t%s' "$@" >> "$FAKE_CALL_LOG"
fi
printf '\n' >> "$FAKE_CALL_LOG"
if [[ "${FAIL_SCRIPT:-}" == "$name" ]]; then
  echo "fixture failure from $name" >&2
  exit 23
fi
if [[ "${MUTATE_SCRIPT:-}" == "$name" ]]; then
  printf 'mutated\n' >> tracked.txt
fi
if [[ "${CREATE_UNTRACKED_SCRIPT:-}" == "$name" ]]; then
  printf 'created by fixture\n' > created-by-check.txt
fi
if [[ "${COMMIT_SCRIPT:-}" == "$name" ]]; then
  git commit --allow-empty -q -m 'test: child moved HEAD'
fi
EOF
chmod +x "$test_root/stub-check.sh"

success_fixture="$(make_fixture success)"
success_log="$test_root/success.calls"
success_output="$test_root/success.out"
(cd "$success_fixture" && FAKE_CALL_LOG="$success_log" bash scripts/ci_local.sh) \
  > "$success_output" 2>&1 || {
    cat "$success_output" >&2
    fail 'clean signed fixture did not pass'
  }
cat > "$test_root/expected.calls" <<EOF
validate_open_source.sh
validate_phone_coder_workflows.sh
test_validate_open_source.sh
test_validate_phone_coder_workflows.sh
test_build_native_frameworks.sh
test_prepare_metal_toolchain_for_codeql.sh
test_resolve_simulator_udid.sh
test_run_with_timeout.sh
test_prepare_unsigned_archive.sh
test_package_unsigned_ipa.sh
validate_dco.sh	$(git -C "$success_fixture" rev-parse refs/remotes/origin/main)	$(git -C "$success_fixture" rev-parse HEAD)
EOF
diff -u "$test_root/expected.calls" "$success_log"
grep -Fq 'LOCAL CI GATE: PASS' "$success_output"
grep -Fq 'REMOTE REQUIRED: macOS/Xcode and GitHub service checks were not executed' "$success_output"
echo 'PASS: clean fixture runs every local check in order and reports remote-only checks'

hook_fixture="$(make_fixture hook)"
mkdir -p "$hook_fixture/nested/directory"
hook_log="$test_root/hook.calls"
hook_output="$test_root/hook.out"
hook_head="$(git -C "$hook_fixture" rev-parse HEAD)"
printf 'refs/heads/feature %s refs/heads/feature %040d\n' "$hook_head" 0 |
  (cd "$hook_fixture/nested/directory" && FAKE_CALL_LOG="$hook_log" \
    ../../.githooks/pre-push origin unused) > "$hook_output" 2>&1 || {
    cat "$hook_output" >&2
    fail 'pre-push hook did not run the gate from a nested directory'
  }
grep -Fq 'LOCAL CI GATE: PASS' "$hook_output"
grep -Fq 'validate_dco.sh' "$hook_log"
echo 'PASS: tracked pre-push hook resolves the checkout root and runs the gate'

foreign_sha="$(printf 'foreign ref fixture\n' | git -C "$hook_fixture" commit-tree \
  "$(git -C "$hook_fixture" rev-parse 'HEAD^{tree}')" -p HEAD)"
foreign_output="$test_root/foreign-ref.out"
if printf 'refs/heads/other %s refs/heads/other %040d\n' "$foreign_sha" 0 |
    (cd "$hook_fixture/nested/directory" && \
      FAKE_CALL_LOG="$test_root/foreign-ref.calls" \
      ../../.githooks/pre-push origin unused) > "$foreign_output" 2>&1; then
  fail 'pre-push hook accepted a pushed commit other than HEAD'
fi
grep -Fq 'refuses a commit other than checked-out HEAD' "$foreign_output"
[[ ! -e "$test_root/foreign-ref.calls" ]] || fail 'gate ran after a foreign ref was rejected'
echo 'PASS: pre-push hook rejects unchecked commits from other local refs'

failure_fixture="$(make_fixture child-failure)"
failure_log="$test_root/child-failure.calls"
failure_output="$test_root/child-failure.out"
failure_status=0
(cd "$failure_fixture" && FAKE_CALL_LOG="$failure_log" \
    FAIL_SCRIPT=test_build_native_frameworks.sh bash scripts/ci_local.sh) \
    > "$failure_output" 2>&1 || failure_status=$?
[[ "$failure_status" == 23 ]] || fail "child failure returned $failure_status instead of 23"
grep -Fq 'FAILED: native framework orchestration regressions' "$failure_output"
grep -Fq 'test_build_native_frameworks.sh' "$failure_log"
if grep -Fq 'test_prepare_metal_toolchain_for_codeql.sh' "$failure_log"; then
  fail 'gate continued after a failed child check'
fi
echo 'PASS: child failure is named and later checks do not run'

invalid_fixture="$(make_fixture invalid-cli)"
invalid_output="$test_root/invalid-cli.out"
status=0
(cd "$invalid_fixture" && FAKE_CALL_LOG="$test_root/invalid-cli.calls" \
  bash scripts/ci_local.sh --unknown) > "$invalid_output" 2>&1 || status=$?
[[ "$status" == 64 ]] || fail "unknown option returned $status instead of 64"
grep -Fq 'usage:' "$invalid_output"
echo 'PASS: unknown options fail with command-line usage status'

base_output="$test_root/invalid-base.out"
if (cd "$invalid_fixture" && FAKE_CALL_LOG="$test_root/invalid-base.calls" \
    bash scripts/ci_local.sh --base refs/remotes/origin/missing) \
    > "$base_output" 2>&1; then
  fail 'missing base ref did not fail the gate'
fi
grep -Fq 'cannot resolve DCO base ref' "$base_output"
[[ ! -e "$test_root/invalid-base.calls" ]] || fail 'checks ran after invalid base ref'
echo 'PASS: invalid DCO base fails before repository checks'

python_fixture="$(make_fixture missing-python-module)"
fake_bin="$test_root/missing-python-module/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/python3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fake_bin/python3"
python_output="$test_root/missing-python-module.out"
if (cd "$python_fixture" && PATH="$fake_bin:$PATH" \
    FAKE_CALL_LOG="$test_root/missing-python-module.calls" bash scripts/ci_local.sh) \
    > "$python_output" 2>&1; then
  fail 'missing PyYAML did not fail the gate'
fi
grep -Fq 'Python 3 with PyYAML 6.0.3 is required' "$python_output"
[[ ! -e "$test_root/missing-python-module.calls" ]] || fail 'checks ran without PyYAML'
echo 'PASS: missing pinned PyYAML fails with an actionable prerequisite error'

mutation_fixture="$(make_fixture mutation)"
mutation_output="$test_root/mutation.out"
if (cd "$mutation_fixture" && FAKE_CALL_LOG="$test_root/mutation.calls" \
    MUTATE_SCRIPT=test_package_unsigned_ipa.sh bash scripts/ci_local.sh) \
    > "$mutation_output" 2>&1; then
  fail 'worktree mutation did not fail the gate'
fi
grep -Fq 'local checks changed the worktree' "$mutation_output"
echo 'PASS: a successful child that mutates the checkout still fails the gate'

dirty_fixture="$(make_fixture already-dirty-mutation)"
printf 'dirty before gate\n' >> "$dirty_fixture/tracked.txt"
dirty_output="$test_root/already-dirty-mutation.out"
if (cd "$dirty_fixture" && FAKE_CALL_LOG="$test_root/already-dirty-mutation.calls" \
    MUTATE_SCRIPT=test_package_unsigned_ipa.sh bash scripts/ci_local.sh) \
    > "$dirty_output" 2>&1; then
  fail 'content change to an already-dirty tracked file did not fail the gate'
fi
grep -Fq 'local checks changed the worktree' "$dirty_output"
echo 'PASS: content changes to an already-dirty tracked file fail the gate'

untracked_fixture="$(make_fixture untracked-mutation)"
untracked_output="$test_root/untracked-mutation.out"
if (cd "$untracked_fixture" && FAKE_CALL_LOG="$test_root/untracked-mutation.calls" \
    CREATE_UNTRACKED_SCRIPT=test_package_unsigned_ipa.sh bash scripts/ci_local.sh) \
    > "$untracked_output" 2>&1; then
  fail 'untracked file creation did not fail the gate'
fi
grep -Fq 'local checks changed the worktree' "$untracked_output"
grep -Fq 'created-by-check.txt' "$untracked_output"
echo 'PASS: a successful child that creates an untracked file still fails the gate'

existing_untracked_fixture="$(make_fixture existing-untracked-mutation)"
printf 'dirty before gate\n' > "$existing_untracked_fixture/created-by-check.txt"
existing_untracked_output="$test_root/existing-untracked-mutation.out"
if (cd "$existing_untracked_fixture" && \
    FAKE_CALL_LOG="$test_root/existing-untracked-mutation.calls" \
    CREATE_UNTRACKED_SCRIPT=test_package_unsigned_ipa.sh bash scripts/ci_local.sh) \
    > "$existing_untracked_output" 2>&1; then
  fail 'content change to an existing untracked file did not fail the gate'
fi
grep -Fq 'local checks changed the worktree' "$existing_untracked_output"
echo 'PASS: content changes to an existing untracked file fail the gate'

head_mutation_fixture="$(make_fixture head-mutation)"
head_mutation_output="$test_root/head-mutation.out"
if (cd "$head_mutation_fixture" && FAKE_CALL_LOG="$test_root/head-mutation.calls" \
    COMMIT_SCRIPT=test_package_unsigned_ipa.sh bash scripts/ci_local.sh) \
    > "$head_mutation_output" 2>&1; then
  fail 'HEAD change with an unchanged file tree did not fail the gate'
fi
grep -Fq 'local checks changed the worktree' "$head_mutation_output"
echo 'PASS: a successful child that moves HEAD still fails the gate'

detached_fixture="$(make_fixture detached-head)"
git -C "$detached_fixture" checkout -q --detach
detached_output="$test_root/detached-head.out"
if (cd "$detached_fixture" && FAKE_CALL_LOG="$test_root/detached-head.calls" \
    bash scripts/ci_local.sh) > "$detached_output" 2>&1; then
  fail 'detached HEAD did not fail the gate'
fi
grep -Fq 'local CI gate requires a branch' "$detached_output"
[[ ! -e "$test_root/detached-head.calls" ]] || fail 'checks ran from detached HEAD'
echo 'PASS: detached HEAD fails before repository checks'

submodule_fixture="$(make_fixture submodule)"
submodule_source="$test_root/submodule/source"
mkdir -p "$submodule_source"
git -C "$submodule_source" init -q
git -C "$submodule_source" config user.name 'Submodule Fixture'
git -C "$submodule_source" config user.email 'submodule@example.test'
printf 'one\n' > "$submodule_source/value.txt"
git -C "$submodule_source" add value.txt
git -C "$submodule_source" commit -q -m 'test: first submodule revision'
git -C "$submodule_fixture" -c protocol.file.allow=always submodule add -q \
  "$submodule_source" ThirdParty/fixture
git -C "$submodule_fixture" commit -qam $'test: add pinned submodule\n\nSigned-off-by: Local Gate Fixture <local-gate@example.test>'
printf 'two\n' >> "$submodule_source/value.txt"
git -C "$submodule_source" commit -qam 'test: second submodule revision'
git -C "$submodule_fixture/ThirdParty/fixture" fetch -q
git -C "$submodule_fixture/ThirdParty/fixture" checkout -q "$(git -C "$submodule_source" rev-parse HEAD)"
submodule_output="$test_root/submodule.out"
if (cd "$submodule_fixture" && FAKE_CALL_LOG="$test_root/submodule.calls" \
    bash scripts/ci_local.sh) > "$submodule_output" 2>&1; then
  fail 'mismatched submodule did not fail the gate'
fi
grep -Fq 'submodules are uninitialized, conflicted, or not at their pinned commits' "$submodule_output"
[[ ! -e "$test_root/submodule.calls" ]] || fail 'checks ran with mismatched submodules'
echo 'PASS: mismatched submodules fail before repository checks'

uninitialized_fixture="$(make_fixture uninitialized-submodule)"
uninitialized_source="$test_root/uninitialized-submodule/source"
mkdir -p "$uninitialized_source"
git -C "$uninitialized_source" init -q
git -C "$uninitialized_source" config user.name 'Submodule Fixture'
git -C "$uninitialized_source" config user.email 'submodule@example.test'
printf 'pinned\n' > "$uninitialized_source/value.txt"
git -C "$uninitialized_source" add value.txt
git -C "$uninitialized_source" commit -q -m 'test: pinned submodule revision'
git -C "$uninitialized_fixture" -c protocol.file.allow=always submodule add -q \
  "$uninitialized_source" ThirdParty/fixture
git -C "$uninitialized_fixture" commit -qam $'test: add submodule\n\nSigned-off-by: Local Gate Fixture <local-gate@example.test>'
git -C "$uninitialized_fixture" submodule deinit -q -f ThirdParty/fixture
uninitialized_output="$test_root/uninitialized-submodule.out"
if (cd "$uninitialized_fixture" && \
    FAKE_CALL_LOG="$test_root/uninitialized-submodule.calls" bash scripts/ci_local.sh) \
    > "$uninitialized_output" 2>&1; then
  fail 'uninitialized submodule did not fail the gate'
fi
grep -Fq 'submodules are uninitialized, conflicted, or not at their pinned commits' \
  "$uninitialized_output"
[[ ! -e "$test_root/uninitialized-submodule.calls" ]] || \
  fail 'checks ran with an uninitialized submodule'
echo 'PASS: uninitialized submodules fail before repository checks'

dirty_submodule_fixture="$(make_fixture dirty-submodule)"
dirty_submodule_source="$test_root/dirty-submodule/source"
mkdir -p "$dirty_submodule_source"
git -C "$dirty_submodule_source" init -q
git -C "$dirty_submodule_source" config user.name 'Submodule Fixture'
git -C "$dirty_submodule_source" config user.email 'submodule@example.test'
printf 'pinned\n' > "$dirty_submodule_source/value.txt"
git -C "$dirty_submodule_source" add value.txt
git -C "$dirty_submodule_source" commit -q -m 'test: pinned submodule revision'
git -C "$dirty_submodule_fixture" -c protocol.file.allow=always submodule add -q \
  "$dirty_submodule_source" ThirdParty/fixture
git -C "$dirty_submodule_fixture" commit -qam $'test: add clean submodule\n\nSigned-off-by: Local Gate Fixture <local-gate@example.test>'
printf 'dirty\n' >> "$dirty_submodule_fixture/ThirdParty/fixture/value.txt"
dirty_submodule_output="$test_root/dirty-submodule.out"
if (cd "$dirty_submodule_fixture" && FAKE_CALL_LOG="$test_root/dirty-submodule.calls" \
    bash scripts/ci_local.sh) > "$dirty_submodule_output" 2>&1; then
  fail 'dirty pinned submodule did not fail the gate'
fi
grep -Fq 'submodule worktrees must be clean' "$dirty_submodule_output"
[[ ! -e "$test_root/dirty-submodule.calls" ]] || fail 'checks ran with a dirty submodule'
echo 'PASS: dirty pinned submodules fail before repository checks'

echo 'All strong local CI gate regressions passed.'
