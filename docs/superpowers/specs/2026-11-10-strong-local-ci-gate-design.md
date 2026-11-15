# Strong Local CI Gate Design

## Intent

Prevent push-and-see development by giving contributors one fail-closed Ubuntu command that exercises every repository-owned check that can run locally. The command must never push, install dependencies, or claim that macOS/GitHub-only work passed.

## Goals

- Run repository hygiene, workflow contracts, mutation regressions, native-build orchestration tests, CodeQL Metal preparation tests, unsigned-archive tests, IPA security tests, whitespace checks, submodule pin checks, and DCO validation.
- Work from any directory inside the checkout and choose a deterministic DCO base, with an explicit `--base` override.
- Stop on the first failure with the failed step named.
- Detect if the gate itself changed the worktree.
- End with separate `PASS` and `REMOTE REQUIRED` summaries.
- Provide an opt-in, tracked pre-push hook that invokes the same command.

## Non-goals

- Emulate Xcode, the iOS Simulator, Apple SDKs, Metal cryptex behavior, or the macOS CodeQL tracer on Ubuntu.
- Replace GitHub Dependency Review, OpenSSF publishing, attestations, or code-scanning upload.
- Download tools, change Git configuration automatically, push, or rerun workflows.

## Constraints and learned practices

- `Podfile.lock`, SwiftPM resolution, submodule SHAs, and workflow action SHAs remain reviewed inputs.
- The gate must preserve the contributor practices visible in commits `850c194`, `d30fe05`, `b92df61`, and `c1056e8`: runner-aligned locks, minimal traced work, destination-owned architecture selection, and content-addressed native caches.
- Ubuntu can test orchestration and hostile fixtures, but a real iOS build remains a mandatory remote macOS check.
- A locally unavailable prerequisite is a gate failure with an installation hint, not an automatic install.

## Approaches

1. **Native Bash orchestrator plus a tracked hook — chosen.** It reuses the exact project scripts, has no new runtime dependency, and is testable in disposable Git fixtures.
2. **Run GitHub Actions through `act` — rejected.** Linux containers cannot reproduce `macos-15`, Xcode, Simulator, Metal cryptex, or the CodeQL macOS tracer.
3. **Generate local commands from workflow YAML — rejected.** GitHub expressions, actions, services, and runner state make this look more exact than it is. The existing workflow-contract validator already prevents drift more safely.

## Design

- `scripts/ci_local.sh` owns prerequisite checks, base selection, ordered execution, worktree mutation detection, and the final local/remote summary.
- `scripts/tests/test_ci_local.sh` copies the orchestrator into disposable signed Git repositories and proves success ordering, failure short-circuiting, invalid CLI handling, missing prerequisites, mutation detection, and hook behavior.
- `.githooks/pre-push` delegates to `scripts/ci_local.sh`; contributors enable it explicitly with `git config core.hooksPath .githooks`. It parses Git's ref stream and rejects any non-deletion ref that does not resolve to the checked-out `HEAD`, so an unchecked side branch cannot bypass the gate.
- The macOS workflow runs the orchestrator regression test, not the orchestrator itself, because the workflow already runs the real macOS jobs individually.
- `CONTRIBUTING.md` and `SETUP_INSTRUCTIONS.md` document the command, hook, and remote-only boundary.

## Success criteria

- A clean disposable fixture runs every expected local command in order and exits zero.
- Any child failure stops later commands and exits nonzero.
- Any tracked/untracked worktree change created during the gate fails the run.
- Missing PyYAML, an invalid base, a detached or invalid repository state, and uninitialized/mismatched submodules fail with actionable messages.
- The real repository local suite passes without modifying the worktree.
