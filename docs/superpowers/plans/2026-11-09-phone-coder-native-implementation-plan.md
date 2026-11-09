# Phone Coder Native Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a native iPhone model server and Ubuntu coding agent derived from the audited OnDevice source, installable without a personally owned Mac.

**Architecture:** Work is divided into five independently testable increments. The iOS fork owns inference, model lifecycle, pairing, and foreground-only API serving; the Ubuntu companion owns repository context, approvals, sandboxed tools, and Codex-like orchestration.

**Tech Stack:** Swift 5.10, SwiftUI, MLX Swift, llama.cpp, Network.framework, XCTest, Python 3.12+, httpx, pytest, Bubblewrap, GitHub Actions, SideStore.

**Spec:** `docs/superpowers/specs/2026-11-09-phone-coder-native-design.md`

## Global Constraints

- Fork baseline is `Mesutcydev/ios-local-llm@cc4e2d3f25dfe77e9ef9e629ee6ddc7e3134ac88`; record every later upstream merge explicitly.
- iOS minimum remains 18.0; required physical qualification device is the owner's iPhone 17 Pro Max.
- Required Ubuntu target is Ubuntu 26.04 LTS x86_64.
- Tailscale-carried HTTP plus bearer authentication is the only release-one remote transport; public Internet and plain LAN exposure are out of scope.
- Serving is foreground-only; backgrounding cancels active work and never resumes the same generation.
- All heavy runtimes pass through memory, thermal, residency, cancellation, and lifecycle policy.
- Release one supports 3B–8B quantized coding models; 70B and multimodal/vision inference are out of scope.
- The sideload build has no undisclosed prompt or image-output classifier. Device safety gates remain mandatory and visibly distinct.
- Repository tools run only on Ubuntu, inside Bubblewrap, with network disabled unless separately approved.
- Do not commit model weights, generated XCFrameworks, Pods, signing material, credentials, user content, or agent transcripts.
- `project.yml` is the source of truth for Xcode project configuration.

## Review Focus

- Cloud runner disk exhaustion while compiling native dependencies: Increment A tests and documents the llama-only build path.
- Duplicate inference after stream reconnection: Increment B fingerprints request bodies and tests same-ID reattachment.
- Workspace escape or credential access from a generated command: Increment C tests Bubblewrap mounts, symlinks, and network denial.
- Hidden policy behavior entering through upstream changes: Increment D adds a machine-readable policy manifest and forbidden-symbol/string tests.
- Simulator success being mistaken for device reliability: Increment E requires recorded physical-device runs for memory, thermal, lifecycle, and soak claims.

---

## Plan Set and Order

1. [Increment A — Native shell, CI, unsigned IPA, and Ubuntu installation](2026-11-09-phone-coder-increment-a-bootstrap.md)
2. [Increment B — Native runtime, API server, pairing, and recovery](2026-11-09-phone-coder-increment-b-native-server.md)
3. [Increment C — Ubuntu coding agent, approvals, and sandboxed tools](2026-11-09-phone-coder-increment-c-ubuntu-agent.md)
4. [Increment D — Image Studio and owner-visible policy](2026-11-09-phone-coder-increment-d-image-policy.md)
5. [Increment E — Accessibility, diagnostics, qualification, and release](2026-11-09-phone-coder-increment-e-release.md)

Each increment ends with working software and a review gate. Do not start the next increment until the previous increment's automated checks pass and its explicit physical/manual checkpoint is recorded.

## Shared Repository Layout

```text
IOSLocalLLM/PhoneCoder/
  App/                 product entry, root navigation, build manifest
  Models/              Phone Coder-owned persisted/value types
  Runtime/             inference coordination and adapters
  Server/              API codecs, ledger, transport, state, activity
  Pairing/             one-time exchange and Keychain-backed client keys
  Policy/              policy manifest and owner controls
  Views/               Chat, Models, Server, Images, Settings
ubuntu-agent/
  src/phone_coder_agent/
  tests/
docs/
  installation/
  qualification/
```

Existing upstream files remain under `IOSLocalLLM/`. New product behavior lives under `IOSLocalLLM/PhoneCoder/` unless a coherent upstream subsystem must be adapted in place.

## Integration Gates

- **After A:** GitHub Actions produces a checksum-verified unsigned IPA and the iPhone launches it through SideStore.
- **After B:** Ubuntu can pair, list a loaded model, stream twenty bounded prompts, cancel, reattach once, and recover after foreground return without duplicate output.
- **After C:** A disposable repository task completes inspect → propose → approve → patch → test → diff entirely through the local phone model.
- **After D:** Image generation works locally and the policy screen proves the shipped sideload flavor has no hidden content classifier.
- **After E:** accessibility, redaction, migration, physical-device soak, licensing, provenance, and recovery documentation pass release review.

## Final Verification

Run the full release matrix documented by Increment E. A release is not complete until the IPA checksum, source commit, dependency lockfiles, policy manifest, automated test results, SideStore installation result, and iPhone 17 Pro Max qualification report are attached to the same release record.
