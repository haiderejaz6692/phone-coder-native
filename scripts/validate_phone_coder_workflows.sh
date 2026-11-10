#!/usr/bin/env bash
# Validate the CI contract without running Xcode or contacting GitHub.
# Requires Python 3 and PyYAML (CI installs PyYAML==6.0.3 in a venv).
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$repository_root" <<'PY'
from pathlib import Path
import hashlib
import re
import shlex
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
    require(workflow["on"]["push"]["branches"] == ["main"],
            "feature branches must build through pull requests, not a reserved prefix")
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

    def contains_text(step_id, *values):
        value = script(step_id)
        for expected in values:
            require(expected in value, f"{step_id} is missing required metadata: {expected}")

    def command_lines(step_id, content=None):
        # The reviewed workflow uses direct commands, not generated shell code.
        # Tokenize logical lines so comments, quoted print arguments, and
        # heredoc bodies cannot impersonate an executable's argv prefix.
        commands = []
        pending = ""
        heredoc = None
        value = script(step_id) if content is None else content
        for line in value.split("\n"):
            if heredoc is not None:
                delimiter, strip_tabs = heredoc
                candidate = line.lstrip("\t") if strip_tabs else line
                if candidate == delimiter:
                    heredoc = None
                continue
            if line.endswith("\\"):
                pending += line[:-1]
                continue
            pending += line + "\n"
            try:
                # Shell operators do not require surrounding whitespace.
                lexer = shlex.shlex(pending, posix=True, punctuation_chars=";&|")
                lexer.whitespace_split = True
                words = list(lexer)
            except ValueError:
                # A quoted print argument may span several physical lines.
                continue
            logical_line = pending
            pending = ""
            if not words:
                continue
            for word in words:
                if word.startswith("<<"):
                    # Only quoted literal inline delimiters are supported;
                    # unquoted bodies have expansion/continuation semantics
                    # beyond this conservative checker. Read <<- from source,
                    # before quote removal,
                    # so a delimiter's quoted hyphen cannot masquerade as it.
                    match = re.search(r'''(?:^|[ \t])<<(-?)(['"])([A-Za-z_][A-Za-z_0-9]*)\2[ \t]*(?:\#.*)?\n$''', logical_line)
                    require(match is not None and heredoc is None,
                            f"{step_id} needs one quoted literal inline heredoc delimiter")
                    heredoc = (match[3], match[1] == "-")
            commands.append(words)
        require(not pending and heredoc is None, f"{step_id} has an unterminated quote or heredoc")
        return commands

    def invokes(commands, command, *arguments):
        prefix = shlex.split(command)
        for words in commands:
            # Environment assignments precede argv, including Validate's PATH.
            while words and re.match(r"^[A-Za-z_][A-Za-z_0-9]*=", words[0]):
                words = words[1:]
            if (words[:len(prefix)] == prefix and all(argument in words for argument in arguments)
                    and not any(re.fullmatch(r"[;&|]+", word) for word in words)):
                return True
        return False

    def executes(step_id, command, *arguments):
        require(invokes(command_lines(step_id), command, *arguments), f"{step_id} must execute {command}")

    executes("tools", "xcodebuild -version")
    executes("tools", "xcodebuild -downloadComponent MetalToolchain")
    executes("tools", "xcodegen --version")
    contains_text("tools", "17A400", "PyYAML==6.0.3")
    for command in ("bash scripts/validate_open_source.sh",
             "bash scripts/validate_phone_coder_workflows.sh",
             "bash scripts/tests/test_validate_phone_coder_workflows.sh",
             "bash scripts/tests/test_validate_open_source.sh",
             "bash scripts/tests/test_build_native_frameworks.sh",
             "bash scripts/tests/test_prepare_metal_toolchain_for_codeql.sh",
             "bash scripts/tests/test_prepare_unsigned_archive.sh",
             "bash scripts/tests/test_package_unsigned_ipa.sh",
             "swift test --package-path Packages/VoiceAgentOrb"):
        executes("repository-tests", command)
    executes("native", "bash scripts/build_native_frameworks.sh --llama-only")
    executes("native", "df -h")
    executes("native", "trap", "df -h", "EXIT")
    native = command_lines("native")
    build_index = next(index for index, words in enumerate(native)
                       if invokes([words], "bash scripts/build_native_frameworks.sh --llama-only"))
    require(any(invokes([words], "df -h") for words in native[:build_index])
            and any(invokes([words], "df -h") for words in native[build_index + 1:]),
            "native compilation must report disk space before and after")
    executes("dependencies", "xcodegen generate")
    executes("dependencies", "pod install --deployment")
    executes("dependencies", "cp", "OnDeviceLAS.xcworkspace/xcshareddata/swiftpm/Package.resolved",
             "PhoneCoder.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    executes("dependencies", "xcodebuild -resolvePackageDependencies", "-onlyUsePackageVersionsFromResolvedFile")
    for step_id, command in (("dependencies", "xcodebuild -resolvePackageDependencies"),
                             ("unit-tests", "xcodebuild test"), ("archive", "xcodebuild archive")):
        executes(step_id, command, "-workspace", "PhoneCoder.xcworkspace", "-scheme", "PhoneCoder", "CODE_SIGNING_ALLOWED=NO")
    executes("unit-tests", "xcodebuild test", "platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0.1",
             "-resultBundlePath", "$RUNNER_TEMP/PhoneCoderTests.xcresult",
             "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile")
    executes("archive", "xcodebuild archive", "generic/platform=iOS", "-configuration", "Release",
             "-archivePath", "$RUNNER_TEMP/PhoneCoder.xcarchive",
             "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile")
    executes("archive", "rm -rf", "$RUNNER_TEMP/PhoneCoder-TestDerivedData")
    executes("package", "bash scripts/prepare_unsigned_archive.sh", "$RUNNER_TEMP/PhoneCoder.xcarchive")
    executes("package", "bash scripts/package_unsigned_ipa.sh")
    executes("package", "bash scripts/verify_unsigned_ipa.sh")
    executes("package", "shasum -a 256 -c")
    contains_text("package", "phone-coder-unsigned-${GITHUB_SHA}.ipa")
    executes("metadata", "python3 -")
    contains_text("metadata", "build-metadata.json", "source_sha", "xcode_version", "dependency_lock_hashes",
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
    require(any(invokes(command_lines("Validate", step.get("run", "")), "bash scripts/validate_phone_coder_workflows.sh")
                for item in jobs.values() for step in item["steps"]), "Validate must run workflow invariants")
    require(any(invokes(command_lines("Validate", step.get("run", "")), "bash scripts/tests/test_validate_phone_coder_workflows.sh")
                for item in jobs.values() for step in item["steps"]), "Validate must run workflow mutation regressions")

    codeql = read_workflow(root / ".github/workflows/codeql.yml")
    swift_job = codeql["jobs"]["swift"]
    require(swift_job["env"]["DEVELOPER_DIR"] == "/Applications/Xcode_26.0.1.app/Contents/Developer",
            "CodeQL must select exact Xcode 26.0.1")
    require(swift_job["env"]["CODEQL_TOOLCHAINS"] ==
            "com.apple.dt.toolchain.XcodeDefault",
            "CodeQL must use the prepared default Xcode toolchain")
    codeql_commands = [
        words
        for step in swift_job["steps"]
        if "run" in step
        for words in command_lines("CodeQL", step["run"])
    ]
    codeql_steps = swift_job["steps"]
    codeql_by_name = {step.get("name"): step for step in codeql_steps}
    prepare_metal_name = "Prepare Xcode Metal toolchain for CodeQL tracing"
    prime_name = "Prime dependency and Metal build outputs before tracing"
    reset_name = "Reset only first-party build outputs for analysis"
    init_name = "Initialize CodeQL"
    verify_metal_name = "Verify Metal toolchain under CodeQL tracing"
    analysis_name = "Build the iOS app for analysis"
    require(all(name in codeql_by_name for name in
                (prepare_metal_name, prime_name, reset_name, init_name,
                 verify_metal_name, analysis_name)),
            "CodeQL must prepare Metal, prime dependencies, and verify Metal under tracing")
    positions = {name: next(index for index, step in enumerate(codeql_steps)
                            if step.get("name") == name)
                 for name in
                 (prepare_metal_name, prime_name, reset_name, init_name,
                  verify_metal_name, analysis_name)}
    require(positions[prepare_metal_name] < positions[prime_name] < positions[reset_name]
            < positions[init_name] < positions[verify_metal_name] < positions[analysis_name],
            "CodeQL Metal preparation/priming must precede initialization and traced verification")
    prepare_metal_commands = command_lines(
        "CodeQL Metal preparation", codeql_by_name[prepare_metal_name]["run"])
    require(invokes(prepare_metal_commands,
                    "bash scripts/prepare_metal_toolchain_for_codeql.sh"),
            "CodeQL must use the reviewed Metal preparation helper before tracer initialization")
    verify_metal_commands = command_lines(
        "CodeQL traced Metal verification", codeql_by_name[verify_metal_name]["run"])
    require(any("TOOLCHAINS=$CODEQL_TOOLCHAINS" in words and
                invokes([words], "xcrun metal -v") for words in verify_metal_commands),
            "CodeQL must prove prepared XcodeDefault Metal remains executable under tracing")
    require(any("TOOLCHAINS=$CODEQL_TOOLCHAINS" in words and invokes(
                    [words], "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/metal", "-v")
                for words in verify_metal_commands),
            "CodeQL must verify the exact grafted Xcode Metal driver used by the app build")
    prime_commands = command_lines("CodeQL prime", codeql_by_name[prime_name]["run"])
    require(invokes(prime_commands, "xcodebuild", "-workspace", "PhoneCoder.xcworkspace",
                    "-scheme", "PhoneCoder", "-derivedDataPath",
                    "$RUNNER_TEMP/PhoneCoder-CodeQLDerivedData", "ARCHS=arm64",
                    "COMPILATION_CACHE_ENABLE_CACHING=NO", "SWIFT_ENABLE_COMPILE_CACHE=NO",
                    "SWIFT_USE_INTEGRATED_DRIVER=NO",
                    "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile",
                    "CODE_SIGNING_ALLOWED=NO"),
            "CodeQL must prime the locked arm64 app build before tracer initialization")
    require(any("TOOLCHAINS=$CODEQL_TOOLCHAINS" in words and invokes([words], "xcodebuild")
                for words in prime_commands),
            "CodeQL priming must use the prepared default Xcode toolchain")
    reset_commands = command_lines("CodeQL reset", codeql_by_name[reset_name]["run"])
    require(invokes(reset_commands, "rm -rf",
                    "$RUNNER_TEMP/PhoneCoder-CodeQLDerivedData/Build/Intermediates.noindex/PhoneCoder.build",
                    "$RUNNER_TEMP/PhoneCoder-CodeQLDerivedData/Build/Products/Debug-iphonesimulator/Phone Coder.app"),
            "CodeQL must invalidate only first-party target outputs before tracing")
    require(invokes(codeql_commands, "pod install --deployment"),
            "CodeQL must install the locked CocoaPods workspace")
    require(invokes(codeql_commands, "xcodebuild -downloadComponent MetalToolchain"),
            "CodeQL must install the pinned Xcode Metal toolchain")
    require(invokes(codeql_commands, "cp",
                    "OnDeviceLAS.xcworkspace/xcshareddata/swiftpm/Package.resolved",
                    "PhoneCoder.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
            "CodeQL must copy the reviewed Swift package graph")
    require(invokes(codeql_commands, "xcodebuild -resolvePackageDependencies",
                    "-workspace", "PhoneCoder.xcworkspace", "-scheme", "PhoneCoder",
                    "-onlyUsePackageVersionsFromResolvedFile"),
            "CodeQL must resolve only the reviewed Swift package graph")
    require(invokes(codeql_commands, "./scripts/build_native_frameworks.sh --llama-only"),
            "CodeQL must build only the release-one native framework")
    require(invokes(codeql_commands, "xcodebuild", "-workspace", "PhoneCoder.xcworkspace",
                    "-scheme", "PhoneCoder", "CODE_SIGNING_ALLOWED=NO",
                    "-derivedDataPath", "$RUNNER_TEMP/PhoneCoder-CodeQLDerivedData", "ARCHS=arm64",
                    "COMPILATION_CACHE_ENABLE_CACHING=NO", "SWIFT_ENABLE_COMPILE_CACHE=NO",
                    "SWIFT_USE_INTEGRATED_DRIVER=NO", "-disableAutomaticPackageResolution",
                    "-onlyUsePackageVersionsFromResolvedFile"),
            "CodeQL must build the Phone Coder workspace and scheme")
    analysis_commands = command_lines("CodeQL analysis build", codeql_by_name[analysis_name]["run"])
    require(any("TOOLCHAINS=$CODEQL_TOOLCHAINS" in words and invokes([words], "xcodebuild")
                for words in analysis_commands),
            "CodeQL traced build must use the prepared default Xcode toolchain")
    podfile_checksum = hashlib.sha1((root / "Podfile").read_bytes()).hexdigest()
    lock_text = (root / "Podfile.lock").read_text(encoding="utf-8")
    require(f"PODFILE CHECKSUM: {podfile_checksum}" in lock_text,
            "Podfile.lock checksum must match Podfile for deployment installs")

    source_release = read_workflow(root / ".github/workflows/source-release.yml")
    require(source_release["on"] == {"push": {"tags": ["v[0-9]+.[0-9]+.[0-9]+"]}},
            "source releases must run only for semantic-version tags")
    release_job = source_release["jobs"]["source-release"]
    release_steps = {step.get("id", step.get("name")): step for step in release_job["steps"]}
    package_script = release_steps["package"]["run"]
    publish_script = release_steps["Publish GitHub release"]["run"]
    require('artifact="phone-coder-${version}-source.tar.gz"' in package_script,
            "source archive must use Phone Coder naming")
    require('--prefix="phone-coder-${version}/"' in package_script,
            "source archive root must use Phone Coder naming")
    require('--title "Phone Coder $RELEASE_TAG"' in publish_script,
            "GitHub source release must use Phone Coder naming")
    release_text = (root / ".github/workflows/source-release.yml").read_text(encoding="utf-8")
    require("ios-local-llm" not in release_text.lower(),
            "source release must not publish the retired product name")
except (KeyError, TypeError, ValueError, AttributeError):
    sys.exit("FAIL: missing or invalid workflow configuration")
print("PASS: Phone Coder CI pins, test gates, unsigned packaging, metadata, and artifact allowlist")
PY
