# Phone Coder Increment C Ubuntu Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Codex-like Ubuntu CLI that uses the iPhone model for reasoning while safely inspecting, patching, testing, and reporting on a selected local repository.

**Architecture:** A Python package separates phone transport, workspace policy, approvals, tools, Bubblewrap execution, context budgeting, and the agent loop. The model proposes typed function calls; the Ubuntu agent validates and authorizes them. A loopback-only OpenAI compatibility proxy supports ordinary chat clients but never exposes repository tools.

**Tech Stack:** Python 3.12+, httpx, pytest, Bubblewrap, argparse, standard-library HTTP server, Git.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`

## Global Constraints

- Required platform is Ubuntu 26.04 LTS x86_64; commands run without login-shell semantics.
- Workspace access is explicit and path-resolved. The user's home, SSH/GPG/cloud credentials, and unrelated repositories are unavailable inside the sandbox.
- Network is disabled for tools by default and enabled only for one separately approved action.
- Read, write, command, network, and destructive actions have distinct policy decisions.
- Tool calls are untrusted model output; names, JSON, path arguments, size, timeouts, and result shape are validated before approval/execution.
- Phone keys are stored in an owner-only configuration file or Secret Service keyring; never in repository files, shell history, logs, or exceptions.
- Task transcripts are memory-only unless workspace history is explicitly enabled.
- Generic loopback proxy clients receive model chat only, never filesystem or shell tools.

## Review Focus

- Symlink/path traversal outside workspace: Tasks 3–5 resolve every target and test hostile links.
- Generated command accessing credentials through inherited environment or mounts: Task 5 supplies a minimal environment and isolated mounts.
- Network-capable command reusing an earlier approval: Task 4 approvals are action-specific, expiring, and non-transferable.
- Stream reconnect duplicating a tool call: Tasks 2 and 6 deduplicate response/tool item IDs.
- Model loop spending unlimited time/tokens: Task 6 enforces turn, tool, token, wall-clock, and output limits.

---

## File Structure

- Create `ubuntu-agent/pyproject.toml` — package/dependencies/entry point.
- Create `ubuntu-agent/src/phone_coder_agent/config.py` — config and protected secret references.
- Create `ubuntu-agent/src/phone_coder_agent/phone_client.py` — native-server client/replay/cancel.
- Create `ubuntu-agent/src/phone_coder_agent/workspace.py` — canonical paths and read/search context.
- Create `ubuntu-agent/src/phone_coder_agent/approval.py` — action/risk decisions.
- Create `ubuntu-agent/src/phone_coder_agent/tools.py` — schemas, validation, dispatch.
- Create `ubuntu-agent/src/phone_coder_agent/sandbox.py` — Bubblewrap command construction/execution.
- Create `ubuntu-agent/src/phone_coder_agent/patching.py` — checked diff application.
- Create `ubuntu-agent/src/phone_coder_agent/agent.py` — bounded tool loop.
- Create `ubuntu-agent/src/phone_coder_agent/cli.py` — pair/chat/run/status/doctor/config commands.
- Create `ubuntu-agent/src/phone_coder_agent/proxy.py` — loopback chat-only proxy.
- Add mirrored focused tests under `ubuntu-agent/tests/`.

### Task 1: Create the package, configuration, and secret boundary

**Files:**
- Create: `ubuntu-agent/pyproject.toml`
- Create: `ubuntu-agent/src/phone_coder_agent/__init__.py`
- Create: `ubuntu-agent/src/phone_coder_agent/config.py`
- Create: `ubuntu-agent/tests/test_config.py`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `PhoneCoderConfig`, `PhoneEndpoint`, `SecretStore`, `FileSecretStore`, `load_config()`.
- Consumes: no earlier interfaces.

- [ ] **Step 1: Write failing config/security tests**

Test default loopback proxy port, Tailscale-only endpoint validation, rejection of public/LAN URLs, owner-only secret-file mode, atomic writes, missing/corrupt config errors, environment-variable key use without serialization, redacted `repr`, and `.phone-coder/` history ignored by Git.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_config.py -q`.

Expected: FAIL because the package does not exist.

- [ ] **Step 3: Implement typed configuration**

Define:

```python
@dataclass(frozen=True)
class PhoneEndpoint:
    base_url: str
    pairing_id: str

@dataclass(frozen=True)
class PhoneCoderConfig:
    endpoint: PhoneEndpoint
    model: str = "iphone-coder"
    proxy_host: str = "127.0.0.1"
    proxy_port: int = 8765
```

Use `~/.config/phone-coder/config.json` and `~/.local/share/phone-coder/credentials/` with mode `0600`; allow a Secret Service adapter later without changing callers.

- [ ] **Step 4: Run tests and package check**

Run:

```bash
python3 -m pytest ubuntu-agent/tests/test_config.py -q
python3 -m pip install -e 'ubuntu-agent[test]'
phone-coder --help
```

Expected: tests PASS and entry point imports.

- [ ] **Step 5: Commit**

```bash
git add ubuntu-agent/pyproject.toml ubuntu-agent/src/phone_coder_agent \
  ubuntu-agent/tests/test_config.py .gitignore
git commit -s -m "feat: add Ubuntu agent configuration"
```

### Task 2: Implement the replay-aware iPhone client

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/phone_client.py`
- Create: `ubuntu-agent/tests/test_phone_client.py`

**Interfaces:**
- Consumes: `PhoneCoderConfig`, bearer key, `phone-coder-api/1` from Increment B.
- Produces: `PhoneClient.models()`, `health()`, `stream_chat()`, `stream_response()`, `cancel()`, `pair_exchange()`.

- [ ] **Step 1: Write failing HTTP/SSE tests with `httpx.MockTransport`**

Cover auth headers, request IDs, strict body shape, SSE Unicode, usage, terminal events, disconnect and identical replay with `Last-Event-ID`, `409 request_conflict`, `410 replay_expired`, cancellation, 401 no-retry, 429 bounded retry, thermal/memory errors, timeout, and logs that redact key/prompt/output.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_phone_client.py -q`; expect missing module failures.

- [ ] **Step 3: Implement transport and retry rules**

Define:

```python
class PhoneClient:
    def health(self) -> Health: ...
    def models(self) -> list[ModelDescriptor]: ...
    def stream_response(self, request: ResponseRequest,
                        request_id: str) -> Iterator[ResponseEvent]: ...
    def cancel(self, request_id: str) -> None: ...
```

Reconnect only with the same request ID/body fingerprint and the last committed event ID. Never retry authentication, conflict, or background terminal errors automatically.

- [ ] **Step 4: Run tests**

Run `python3 -m pytest ubuntu-agent/tests/test_phone_client.py -q`.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/phone_client.py ubuntu-agent/tests/test_phone_client.py
git commit -s -m "feat: add replay-aware iPhone client"
```

### Task 3: Enforce workspace boundaries and bounded read context

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/workspace.py`
- Create: `ubuntu-agent/tests/test_workspace.py`

**Interfaces:**
- Produces: `Workspace`, `WorkspacePath`, `SearchResult`, `ReadResult`, `ContextBudget`.
- Consumes: pathlib, `rg`, and configured workspace root.

- [ ] **Step 1: Write failing path/search/read tests**

Test relative and absolute targets, `..`, symlinks to outside files/directories, broken links, hard-link disclosure note, ignored `.git` and secret-pattern paths, binary files, huge files, Unicode, line ranges, search result cap, timeout, unavailable `rg` fallback, and a workspace root that is itself a symlink.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_workspace.py -q`; expect missing types.

- [ ] **Step 3: Implement canonical workspace policy**

Expose:

```python
class Workspace:
    def resolve(self, relative: str, *, must_exist: bool = True) -> WorkspacePath: ...
    def list(self, relative: str = ".", limit: int = 500) -> list[WorkspaceEntry]: ...
    def read(self, relative: str, start: int | None = None,
             end: int | None = None, max_bytes: int = 131072) -> ReadResult: ...
    def search(self, pattern: str, globs: tuple[str, ...] = (),
               limit: int = 200) -> list[SearchResult]: ...
```

Every resolved target must remain beneath the canonical root after symlink resolution. Redact configured secret filename patterns before returning content.

- [ ] **Step 4: Run tests**

Run workspace tests under a temporary repository containing hostile symlinks.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/workspace.py ubuntu-agent/tests/test_workspace.py
git commit -s -m "feat: enforce workspace boundaries"
```

### Task 4: Implement approval policy and audit records

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/approval.py`
- Create: `ubuntu-agent/tests/test_approval.py`

**Interfaces:**
- Produces: `ActionKind`, `RiskLevel`, `ProposedAction`, `ApprovalDecision`, `ApprovalEngine`, `AuditStore`.
- Consumes: validated tool arguments, not raw model JSON.

- [ ] **Step 1: Write failing policy tests**

Cover safe read auto-approval profile, writes requiring review, commands requiring review, network separate approval, destructive/privileged actions denied, one decision bound to exact action digest, expiry, rejection, prompt cancellation, non-interactive mode fail-closed, seven-day metadata pruning, and redaction of command arguments/paths marked secret.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_approval.py -q`; expect missing types.

- [ ] **Step 3: Implement the approval engine**

```python
class ApprovalEngine:
    def classify(self, action: ProposedAction) -> RiskLevel: ...
    def decide(self, action: ProposedAction, interactive: bool) -> ApprovalDecision: ...
    def verify(self, action: ProposedAction, decision: ApprovalDecision) -> None: ...
```

Persist only action type, decision, timestamp, risk, and redacted target. A decision cannot authorize a different digest or later tool call.

- [ ] **Step 4: Run tests**

Run `test_approval.py`; expect PASS.

- [ ] **Step 5: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/approval.py ubuntu-agent/tests/test_approval.py
git commit -s -m "feat: add scoped agent approvals"
```

### Task 5: Add safe patch and Bubblewrap command tools

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/patching.py`
- Create: `ubuntu-agent/src/phone_coder_agent/sandbox.py`
- Create: `ubuntu-agent/src/phone_coder_agent/tools.py`
- Create: `ubuntu-agent/tests/test_patching.py`
- Create: `ubuntu-agent/tests/test_sandbox.py`
- Create: `ubuntu-agent/tests/test_tools.py`

**Interfaces:**
- Consumes: Workspace, ApprovalEngine.
- Produces: typed tool schemas and `ToolDispatcher.execute(call) -> ToolResult`.

- [ ] **Step 1: Write failing patch tests**

Test `git apply --check`, exact workspace paths, new/modified/deleted files, malformed/binary patches, path traversal, symlink targets, dirty overlap reporting, size limits, rejected approval, atomic failure, and resulting diff summary.

- [ ] **Step 2: Write failing sandbox tests**

Assert Bubblewrap command includes a writable workspace bind, read-only minimal system mounts, private temporary home/tmp, cleared environment, no host home/SSH/GPG access, no network by default, explicit network mode only with matching approval, wall/output/process limits, cancellation, and missing Bubblewrap fail-closed.

- [ ] **Step 3: Run and confirm RED**

Run the three focused suites; expect missing modules.

- [ ] **Step 4: Implement tool schemas, patching, and command execution**

Initial tool names are `workspace_list`, `workspace_search`, `workspace_read`, `apply_patch`, `run_command`, `git_status`, `git_diff`, and `run_tests`. Reject unknown tools and extra schema fields. Commands accept argument arrays, never a shell string; explicit shell use is a separately classified command.

- [ ] **Step 5: Run focused and live sandbox tests**

Run:

```bash
python3 -m pytest ubuntu-agent/tests/test_patching.py ubuntu-agent/tests/test_sandbox.py ubuntu-agent/tests/test_tools.py -q
bwrap --unshare-all --die-with-parent --ro-bind /usr /usr --proc /proc --dev /dev true
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/{patching,sandbox,tools}.py \
  ubuntu-agent/tests/test_{patching,sandbox,tools}.py
git commit -s -m "feat: add sandboxed coding tools"
```

### Task 6: Implement the bounded coding-agent loop

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/agent.py`
- Create: `ubuntu-agent/src/phone_coder_agent/context.py`
- Create: `ubuntu-agent/tests/test_agent.py`
- Create: `ubuntu-agent/tests/test_context.py`

**Interfaces:**
- Consumes: PhoneClient, Workspace, ToolDispatcher, ApprovalEngine.
- Produces: `CodingAgent.run(task) -> AgentResult`, stable tool-call/result conversation items, final verification summary.

- [ ] **Step 1: Write failing context tests**

Test repository summary budget, user-task priority, recent tool-result grouping, truncation at complete item boundaries, binary/secret exclusion, oversized tool output summarization, and explicit `context_length_exceeded` retry with smaller context/new request ID.

- [ ] **Step 2: Write failing loop tests with scripted model events**

Cover text-only final, one and multiple tool calls, malformed JSON, unknown tool, duplicate response item IDs after reconnect, rejected approval, tool error returned to model, max turns/tools/tokens/wall time, cancellation, phone background terminal, and final result listing actual changed files/tests. Ensure no tool call executes twice.

- [ ] **Step 3: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_agent.py ubuntu-agent/tests/test_context.py -q`; expect missing modules.

- [ ] **Step 4: Implement bounded orchestration**

Set release-one defaults: at most 12 model turns, 24 tool calls, 20 minutes wall time, 256 KiB per tool result before summarization, and one context-compaction retry. Only terminal `AgentResult` may claim a test passed, and it must cite the captured exit code.

- [ ] **Step 5: Run tests**

Run agent/context suites; expect PASS.

- [ ] **Step 6: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/{agent,context}.py \
  ubuntu-agent/tests/test_{agent,context}.py
git commit -s -m "feat: add bounded local coding agent"
```

### Task 7: Build the user-facing CLI

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/cli.py`
- Create: `ubuntu-agent/tests/test_cli.py`
- Modify: `ubuntu-agent/pyproject.toml`
- Create: `docs/ubuntu-agent.md`

**Interfaces:**
- Consumes: Tasks 1–6 services.
- Produces: `phone-coder pair|status|models|chat|run|stop|doctor|config`.

- [ ] **Step 1: Write failing CLI tests**

Test help, exit codes, missing configuration, pairing without key leakage, non-TTY approval fail-closed, SIGINT cancel, streamed text, structured errors, workspace selection, `run` final summary, `doctor` checks for Tailscale/Bubblewrap/key permissions/phone health, and no ANSI when not a TTY.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_cli.py -q`; expect missing commands.

- [ ] **Step 3: Implement commands with argparse**

Keep prompts and outputs out of logs. Display connection/model/context/action state, require an explicit workspace for `run`, and print changed files plus tests at completion.

- [ ] **Step 4: Run tests and smoke commands**

Run the CLI suite and `phone-coder doctor --json` against a fake phone server.

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/cli.py ubuntu-agent/tests/test_cli.py \
  ubuntu-agent/pyproject.toml docs/ubuntu-agent.md
git commit -s -m "feat: add Phone Coder Ubuntu CLI"
```

### Task 8: Add the loopback chat-only compatibility proxy

**Files:**
- Create: `ubuntu-agent/src/phone_coder_agent/proxy.py`
- Create: `ubuntu-agent/tests/test_proxy.py`
- Modify: `ubuntu-agent/src/phone_coder_agent/cli.py`

**Interfaces:**
- Consumes: PhoneClient chat/models only.
- Produces: `phone-coder serve` at `127.0.0.1:8765/v1` with `/models` and `/chat/completions`.

- [ ] **Step 1: Write failing proxy tests**

Test loopback bind enforcement, local bearer option, models/chat streaming/non-streaming, disconnect cancellation, upstream error mapping, max body, no CORS wildcard, unsupported tool/repository fields, concurrent queue behavior, and refusal to bind `0.0.0.0`.

- [ ] **Step 2: Run and confirm RED**

Run `python3 -m pytest ubuntu-agent/tests/test_proxy.py -q`; expect missing server.

- [ ] **Step 3: Implement the compatibility proxy**

Use `ThreadingHTTPServer`, bounded request bodies, current PhoneClient, and graceful SIGTERM. The proxy forwards chat inference only; it never instantiates Workspace, ApprovalEngine, ToolDispatcher, or CodingAgent.

- [ ] **Step 4: Run tests and editor-client smoke request**

Run proxy tests, then curl `/v1/models` and a streaming completion through a fake/real phone.

Expected: PASS with no repository capability exposed.

- [ ] **Step 5: Commit**

```bash
git add ubuntu-agent/src/phone_coder_agent/{proxy,cli}.py ubuntu-agent/tests/test_proxy.py
git commit -s -m "feat: add loopback chat proxy"
```

### Task 9: End-to-end disposable repository qualification

**Files:**
- Create: `ubuntu-agent/tests/e2e/test_disposable_repo.py`
- Create: `docs/qualification/ubuntu-agent-iphone17promax.md`

**Interfaces:**
- Consumes: all Increment B/C interfaces.
- Produces: recorded inspect → patch → test → diff evidence.

- [ ] **Step 1: Create deterministic disposable-repository fixtures**

Include one failing Python test, a target source bug, unrelated dirty work, an outside-workspace secret, a hostile symlink, and a command that attempts network access.

- [ ] **Step 2: Run scripted-model end-to-end tests**

Prove correct inspection, approval, patch, passing test, preserved unrelated dirty work, blocked secret/symlink/network attempts, rejection behavior, and final changed-file/test summary.

- [ ] **Step 3: Run the same task with the physical iPhone model**

Use the qualified coding model, record prompts only as hashes/fixtures, approve the minimal patch/test actions, and capture model/tool/verification outcomes without private repository content.

- [ ] **Step 4: Record model limitations**

Report tool-call success rate, malformed calls, retries, token/time use, patch correctness, and whether the chosen model is acceptable for release-one agent mode.

- [ ] **Step 5: Commit fixtures/report**

```bash
git add ubuntu-agent/tests/e2e docs/qualification/ubuntu-agent-iphone17promax.md
git commit -s -m "test: qualify Phone Coder coding loop"
```

## Increment C Completion Check

Run all Ubuntu tests, lint/type checks selected in `pyproject.toml`, live Bubblewrap probes, loopback proxy tests, scripted end-to-end fixtures, and the physical iPhone disposable-repository task. Increment C is complete only when no model output can bypass validation, approval, workspace boundaries, or sandbox policy.
