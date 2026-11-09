#!/usr/bin/env bash
# Run the actual invariant checker against disposable workflow mutations.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repository_root" <<'PY'
import copy
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

import yaml

root = Path(sys.argv[1])
original = yaml.load((root / ".github/workflows/phone-coder-ios.yml").read_text(), Loader=yaml.BaseLoader)

def replace_command(workflow, step_id, command, replacement):
    step = next(step for step in workflow["jobs"]["phone-coder-ios"]["steps"] if step["id"] == step_id)
    assert step["run"].count(command) == 1, "mutation must alter exactly one real command"
    step["run"] = step["run"].replace(command, replacement)

mutations = [
    ("commented IPA verifier", "package", "bash scripts/verify_unsigned_ipa.sh", "# bash scripts/verify_unsigned_ipa.sh"),
    ("commented Swift package tests", "repository-tests", "swift test --package-path Packages/VoiceAgentOrb", "# swift test --package-path Packages/VoiceAgentOrb"),
    ("echoed XCTest command", "unit-tests", "xcodebuild test", "echo xcodebuild test"),
    ("printed IPA verifier", "package", "bash scripts/verify_unsigned_ipa.sh", "printf '%s\\n' 'bash scripts/verify_unsigned_ipa.sh'"),
    ("multiline quoted test text", "repository-tests", "swift test --package-path Packages/VoiceAgentOrb", "printf '%s\\n' 'example:\nswift test --package-path Packages/VoiceAgentOrb\n'"),
    ("heredoc verifier text", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<'EXAMPLE'\nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("space-padded false heredoc delimiter", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<'EXAMPLE'\n EXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("trailing-space false heredoc delimiter", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<'EXAMPLE'\nEXAMPLE \nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("tab-padded ordinary heredoc delimiter", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<'EXAMPLE'\n\tEXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("space-padded false tab-stripping delimiter", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<-'EXAMPLE'\n EXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("trailing-space false tab-stripping delimiter", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<-'EXAMPLE'\n\tEXAMPLE \nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("unspaced failure-swallowing true", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', 'bash scripts/verify_unsigned_ipa.sh "$ipa" ||true'),
    ("unspaced failure-swallowing colon", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', 'bash scripts/verify_unsigned_ipa.sh "$ipa"||:'),
    ("unspaced background success", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', 'bash scripts/verify_unsigned_ipa.sh "$ipa"&true'),
    ("unquoted heredoc continuation hides verifier", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<EXAMPLE\nnot-end\\\nEXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
    ("unquoted tab-stripping continuation hides verifier", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<-EXAMPLE\nnot-end\\\n\tEXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\"\nEXAMPLE"),
]
positive_mutations = [
    ("tab-stripping heredoc with a real verifier after its terminator", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<-'EXAMPLE'\n\tprinted example\n\tEXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\""),
    ("quoted heredoc preserves a literal backslash before its terminator", "package", 'bash scripts/verify_unsigned_ipa.sh "$ipa"', "cat <<'EXAMPLE'\nnot-end\\\nEXAMPLE\nbash scripts/verify_unsigned_ipa.sh \"$ipa\""),
]
failures = []
with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    (fixture / "scripts").mkdir()
    (fixture / ".github/workflows").mkdir(parents=True)
    shutil.copyfile(root / "scripts/validate_phone_coder_workflows.sh", fixture / "scripts/validate_phone_coder_workflows.sh")
    shutil.copyfile(root / ".github/workflows/validate.yml", fixture / ".github/workflows/validate.yml")

    def validate(workflow):
        (fixture / ".github/workflows/phone-coder-ios.yml").write_text(yaml.safe_dump(workflow, sort_keys=False))
        return subprocess.run(["bash", str(fixture / "scripts/validate_phone_coder_workflows.sh")], capture_output=True, text=True)

    baseline = validate(original)
    assert baseline.returncode == 0, baseline.stdout + baseline.stderr
    print("PASS: unchanged workflow is accepted")
    for name, step_id, command, replacement in mutations:
        changed = copy.deepcopy(original)
        replace_command(changed, step_id, command, replacement)
        script = next(step["run"] for step in changed["jobs"]["phone-coder-ios"]["steps"] if step["id"] == step_id)
        subprocess.run(["bash", "-n"], input=script, text=True, check=True)
        result = validate(changed)
        if result.returncode != 1 or "FAIL:" not in result.stdout + result.stderr:
            failures.append(name)
            print(f"FAIL: accepted {name}")
        else:
            print(f"PASS: rejects {name}")
    for name, step_id, command, replacement in positive_mutations:
        changed = copy.deepcopy(original)
        replace_command(changed, step_id, command, replacement)
        result = validate(changed)
        if result.returncode != 0:
            failures.append(name)
            print(f"FAIL: rejected {name}")
        else:
            print(f"PASS: accepts {name}")
if failures:
    sys.exit(1)
print("All workflow command mutation regressions passed.")
PY
