# Strong Local CI Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a tested, fail-closed Ubuntu pre-push gate that runs every locally reproducible Phone Coder CI check and reports remote-only checks honestly.

**Architecture:** A Bash orchestrator calls the existing validation and fixture suites in a fixed order, with Git/submodule/DCO preconditions and before/after worktree snapshots. A tracked pre-push hook delegates to it; disposable Git fixtures test orchestration without running Xcode.

**Tech Stack:** Bash, Git, Python 3 with PyYAML, existing repository shell tests.

**Spec:** `docs/superpowers/specs/2026-11-10-strong-local-ci-gate-design.md`

## Global Constraints

- Do not install dependencies, push, rerun workflows, or change Git configuration automatically.
- Do not mark macOS/GitHub-only checks as passed.
- Default the DCO base deterministically and accept one explicit `--base REF` override.
- Preserve all existing workflow contract and security tests.

## Review Focus

- A missing or invalid base ref must fail before tests begin.
- A child process failure must stop later checks and retain its exit status as a gate failure.
- A test that mutates the checkout must be detected even when it exits zero.
- Uninitialized or mismatched submodules must fail with their status shown.
- Hook execution from a nested directory must still locate the checkout and run the gate.

---

### Task 1: Local gate orchestration

**Files:**
- Create: `scripts/ci_local.sh`
- Create: `scripts/tests/test_ci_local.sh`

**Interfaces:**
- Consumes: existing validators and shell regression tests; optional `--base REF`.
- Produces: exit `0` only when all local checks pass without mutating the checkout; a `REMOTE REQUIRED` list for unexecuted checks.

- [x] **Step 1: Write fixture tests for success ordering, child failure, invalid CLI/base, missing PyYAML, dirty-state mutation, and submodule rejection.**
- [x] **Step 2: Run `bash scripts/tests/test_ci_local.sh` and verify it fails because `scripts/ci_local.sh` does not exist.**
- [x] **Step 3: Implement the minimal orchestrator and actionable summary.**
- [x] **Step 4: Run the fixture test and existing local suites to green.**

### Task 2: Pre-push integration and workflow contract

**Files:**
- Create: `.githooks/pre-push`
- Modify: `.github/workflows/phone-coder-ios.yml`
- Modify: `scripts/validate_phone_coder_workflows.sh`
- Modify: `scripts/tests/test_validate_phone_coder_workflows.sh`
- Modify: `scripts/validate_open_source.sh`
- Modify: `CONTRIBUTING.md`
- Modify: `SETUP_INSTRUCTIONS.md`

**Interfaces:**
- Consumes: `scripts/ci_local.sh` from Task 1.
- Produces: an opt-in hook and enforced regression coverage for the gate.

- [x] **Step 1: Extend fixture and workflow mutation tests before integration changes.**
- [x] **Step 2: Run the focused tests and verify the missing hook/workflow command failures.**
- [x] **Step 3: Add the hook, executable validation, workflow regression invocation, and documentation.**
- [x] **Step 4: Run the complete local gate, all repository shell suites, and `git diff --check`.**
- [x] **Step 5: Review the final diff; do not push automatically.**
