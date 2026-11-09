#!/usr/bin/env bash
# Validate the CI contract without running Xcode or contacting GitHub.
# Requires Python 3 and PyYAML (CI installs PyYAML==6.0.3 in a venv).
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repository_root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
workflow_path = root / ".github/workflows/phone-coder-ios.yml"

def require(condition, message):
    if not condition:
        sys.exit(f"FAIL: {message}")

require(workflow_path.is_file(), ".github/workflows/phone-coder-ios.yml is missing")
try:
    import yaml
except ImportError:
    sys.exit("FAIL: PyYAML is required; install PyYAML==6.0.3 in a Python venv")

class UniqueLoader(yaml.BaseLoader):
    # BaseLoader keeps GitHub's YAML 1.2 'on' key and boolean strings intact.
    def construct_mapping(self, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            require(key not in result, "duplicate workflow mapping key")
            result[key] = self.construct_object(value_node, deep=deep)
        return result

def read_workflow(path):
    try:
        value = yaml.load(path.read_text(encoding="utf-8"), Loader=UniqueLoader)
        require(isinstance(value, dict), "workflow must be a mapping")
        return value
    except (OSError, yaml.YAMLError):
        sys.exit("FAIL: workflow cannot be read as YAML")

try:
    workflow = read_workflow(workflow_path)
    require(set(workflow["on"]) == {"push", "pull_request", "workflow_dispatch"},
            "build must use ordinary push/PR/manual events only")
    require(workflow["permissions"] == {"contents": "read"}, "build permissions must be read-only")
    require(set(workflow["jobs"]) == {"phone-coder-ios"}, "expected one Phone Coder build job")
    job = workflow["jobs"]["phone-coder-ios"]
    require(job["runs-on"] == "macos-15", "build must pin macos-15 (never macos-latest)")
    require(job["env"]["DEVELOPER_DIR"] == "/Applications/Xcode_26.0.1.app/Contents/Developer",
            "build must select exact Xcode 26.0.1")
    require(job["env"]["CODE_SIGNING_ALLOWED"] == "NO", "job signing must be disabled")
    require(job["env"]["POLICY_FLAVOR"] == "sideload-owner-controlled", "wrong policy flavor")
    require(job["env"]["API_PROFILE"] == "phone-coder-api/1", "wrong API profile")
    require(job["defaults"]["run"]["shell"] == "bash", "run scripts must fail on errors via bash")
    require(0 < int(job["timeout-minutes"]) <= 120, "build needs a bounded timeout")
    require("permissions" not in job and "continue-on-error" not in job, "job cannot override security gates")
    steps = job["steps"]
    ids = [step.get("id") for step in steps if "id" in step]
    require(len(set(ids)) == len(ids), "step IDs must be unique")
    expected = ["checkout", "tools", "repository-tests", "native", "dependencies",
                "unit-tests", "archive", "package", "metadata", "upload"]
    require(ids == expected, "dependency/test/archive/verification/upload gates must remain ordered")
    by_id = {step["id"]: step for step in steps if "id" in step}
    require(len(steps) == len(expected), "unexpected build step outside the reviewed build contract")
    for step in steps:
        require("if" not in step and "continue-on-error" not in step,
                "all build gates and upload must require prior success")
        if "uses" in step:
            require(re.fullmatch(r"actions/(checkout|upload-artifact)@[0-9a-f]{40}", step["uses"]),
                    "actions must use reviewed repositories and full commit SHAs")
    checkout = by_id["checkout"]
    require(checkout["uses"].startswith("actions/checkout@"), "missing source checkout")
    require(checkout["with"]["submodules"] == "recursive", "checkout must include pinned submodules")
    require(checkout["with"]["persist-credentials"] == "false", "checkout cannot retain credentials")

    def script(step_id):
        value = by_id[step_id]["run"]
        require(isinstance(value, str), f"{step_id} needs a run script")
        return value

    def contains(step_id, *commands):
        value = script(step_id)
        for command in commands:
            require(command in value, f"{step_id} must execute {command}")

    contains("tools", "xcodebuild -version", "17A400", "PyYAML==6.0.3", "xcodegen")
    contains("repository-tests", "bash scripts/validate_open_source.sh",
             "bash scripts/validate_phone_coder_workflows.sh",
             "bash scripts/tests/test_validate_open_source.sh",
             "bash scripts/tests/test_build_native_frameworks.sh",
             "bash scripts/tests/test_package_unsigned_ipa.sh",
             "swift test --package-path Packages/VoiceAgentOrb")
    contains("native", "bash scripts/build_native_frameworks.sh --llama-only")
    native = script("native")
    require(native.index("df -h") < native.index("build_native_frameworks.sh") < native.rindex("df -h"),
            "native compilation must report disk space before and after")
    require("trap 'df -h' EXIT" in native, "native failures must also report disk space")
    contains("dependencies", "xcodegen generate", "pod install",
             "OnDeviceLAS.xcworkspace/xcshareddata/swiftpm/Package.resolved",
             "PhoneCoder.xcworkspace/xcshareddata/swiftpm/Package.resolved",
             "-resolvePackageDependencies", "-onlyUsePackageVersionsFromResolvedFile")
    for step_id in ("dependencies", "unit-tests", "archive"):
        contains(step_id, "-workspace PhoneCoder.xcworkspace", "-scheme PhoneCoder", "CODE_SIGNING_ALLOWED=NO")
    contains("unit-tests", "xcodebuild test", "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1",
             '-resultBundlePath "$RUNNER_TEMP/PhoneCoderTests.xcresult"',
             "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile")
    contains("archive", "xcodebuild archive", "generic/platform=iOS", "-configuration Release",
             '-archivePath "$RUNNER_TEMP/PhoneCoder.xcarchive"',
             'rm -rf "$RUNNER_TEMP/PhoneCoder-TestDerivedData"',
             "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile")
    contains("package", "bash scripts/package_unsigned_ipa.sh", "bash scripts/verify_unsigned_ipa.sh",
             "phone-coder-unsigned-${GITHUB_SHA}.ipa", "shasum -a 256 -c")
    contains("metadata", "build-metadata.json", "source_sha", "xcode_version", "dependency_lock_hashes",
             "policy_flavor", "api_profile", "hashlib.sha256", "Podfile.lock",
             "PhoneCoder.xcworkspace/xcshareddata/swiftpm/Package.resolved",
             'os.environ["GITHUB_SHA"]', 'os.environ["POLICY_FLAVOR"]', 'os.environ["API_PROFILE"]')
    upload = by_id["upload"]
    require(upload["uses"].startswith("actions/upload-artifact@"), "missing artifact upload")
    require(upload["with"]["if-no-files-found"] == "error", "missing artifacts must fail the run")
    require(upload["with"]["include-hidden-files"] == "false", "hidden files cannot be uploaded")
    paths = set(upload["with"]["path"].splitlines())
    require(paths == {
        "${{ runner.temp }}/phone-coder-artifacts/phone-coder-unsigned-${{ github.sha }}.ipa",
        "${{ runner.temp }}/phone-coder-artifacts/phone-coder-unsigned-${{ github.sha }}.ipa.sha256",
        "${{ runner.temp }}/phone-coder-artifacts/build-metadata.json",
        "${{ runner.temp }}/PhoneCoderTests.xcresult",
    }, "uploads must allowlist only the IPA, checksum, metadata, and test result")
    require(upload["with"]["name"] == "phone-coder-unsigned-${{ github.sha }}", "artifact must identify source SHA")
    text = workflow_path.read_text(encoding="utf-8")
    require(not re.search(r"secrets\s*[.\[]|pull_request_target|security\s+(?:import|create-keychain)|"
                          r"(?:codesign|xcodebuild\s+-exportArchive)\b|PROVISIONING_PROFILE|"
                          r"APPLE_(?:ID|PASSWORD)|MATCH_PASSWORD|DEVELOPMENT_TEAM", text, re.I),
            "unsigned workflow must not reference signing secrets, privileged events, or signing commands")

    validation = read_workflow(root / ".github/workflows/validate.yml")
    jobs = validation["jobs"]
    require(jobs["repository"]["runs-on"] == "ubuntu-latest", "preserve repository validation runner")
    require(any(step.get("run") == "./scripts/validate_open_source.sh"
                for step in jobs["repository"]["steps"]), "preserve repository hygiene validation")
    require(jobs["voice-orb"]["runs-on"] == "macos-15", "preserve VoiceAgentOrb runner")
    require(any(step.get("run") == "swift test --package-path Packages/VoiceAgentOrb"
                for step in jobs["voice-orb"]["steps"]), "preserve VoiceAgentOrb tests")
    require(any("bash scripts/validate_phone_coder_workflows.sh" in step.get("run", "")
                for item in jobs.values() for step in item["steps"]), "Validate must run workflow invariants")
except (KeyError, TypeError, ValueError, AttributeError):
    sys.exit("FAIL: missing or invalid workflow configuration")
print("PASS: Phone Coder CI pins, test gates, unsigned packaging, metadata, and artifact allowlist")
PY
