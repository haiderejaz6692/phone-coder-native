# Contributing

Thanks for helping improve iOS Local LLM.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large architectural change.
- Keep changes focused and explain the user-facing effect.
- Do not add model weights, generated frameworks, signing files, credentials,
  or third-party material without a reviewed redistribution license.

## Development workflow

1. Fork the repository and clone it with submodules.
2. Create a branch from `main`.
3. Follow [SETUP_INSTRUCTIONS.md](SETUP_INSTRUCTIONS.md).
4. Add or update tests for behavior changes.
5. Run `./scripts/ci_local.sh`. It fails on the first locally reproducible CI
   problem and reports the macOS/GitHub checks that still require CI.
6. Sign off each commit with `git commit -s` to certify the
   [Developer Certificate of Origin](https://developercertificate.org/).
7. Open a pull request using the repository template.

To run the same gate automatically before each push, opt in once per clone:

```bash
git config core.hooksPath .githooks
```

The hook never installs dependencies, changes files, pushes, or claims that
Xcode and GitHub-hosted service checks passed. It rejects pushes of another
local branch; check out that branch so its own `HEAD` is validated first.

## Code style

- Follow the surrounding Swift and SwiftUI conventions.
- Prefer small, testable types and explicit error handling.
- Keep UI work accessible with Dynamic Type and VoiceOver.
- Avoid unrelated formatting or generated-project churn.
- Update `project.yml` before regenerating the Xcode project.

## Licensing

By submitting a contribution, you agree that your contribution is licensed
under the repository's MIT license. You confirm that you have the right to
submit it. The `Signed-off-by` line certifies the Developer Certificate of
Origin; it is not a copyright assignment.

Clearly identify code or assets adapted from another source and include its
copyright and license notice. A URL alone is not a substitute for permission
to redistribute.

## AI-assisted contributions

AI tools may be used, but contributors remain responsible for understanding,
reviewing, testing, and maintaining everything they submit. Mention material
AI assistance in the pull request when it would help reviewers assess the
change.

## Conduct and security

Participating in this project means following
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Do not disclose vulnerabilities in a
public issue; use [SECURITY.md](SECURITY.md).
