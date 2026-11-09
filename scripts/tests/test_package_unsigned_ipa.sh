#!/usr/bin/env bash
# Real ZIP/filesystem checks against disposable fake app bundles; no Apple build.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repository_root" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import zipfile

root = Path(sys.argv[1])
package = root / "scripts/package_unsigned_ipa.sh"
verify = root / "scripts/verify_unsigned_ipa.sh"

def check(condition, message):
    if not condition:
        raise AssertionError(message)

def run(script, *args, portable=True):
    env = dict(os.environ)
    env.pop("PHONE_CODER_PORTABLE_TEST", None)
    if portable:
        env["PHONE_CODER_PORTABLE_TEST"] = "1"
    return subprocess.run(["bash", str(script), *map(str, args)], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

def success(result):
    check(result.returncode == 0, result.stdout)

def reject(result, reason):
    check(result.returncode != 0, f"accepted {reason}")

def app_fixture(parent):
    app = parent / "Phone Coder.app"
    app.mkdir(parents=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "Phone Coder", "CFBundleIdentifier": "com.haider.phonecoder",
        "CFBundlePackageType": "APPL"}))
    (app / "Phone Coder").write_bytes(b"fake executable\n")
    (app / "Phone Coder").chmod(0o755)
    (app / "Assets.car").write_bytes(b"fixture assets")
    (app / "Frameworks/llama.framework").mkdir(parents=True)
    (app / "Frameworks/llama.framework/llama").write_bytes(b"fake framework\n")
    (app / "Frameworks/llama.framework/llama").chmod(0o755)
    return app

def raw_zip(app, output, transform=None, extra=None):
    # Deliberately bypass packaging so verifier rejection is independently tested.
    with zipfile.ZipFile(output, "w") as archive:
        for path in sorted(app.rglob("*")):
            if path.is_file():
                name = "Payload/Phone Coder.app/" + path.relative_to(app).as_posix()
                if transform:
                    name = transform(name)
                if name:
                    archive.write(path, name)
        if extra:
            name, data, mode = extra
            info = zipfile.ZipInfo(name)
            info.create_system = 3
            info.external_attr = mode << 16
            archive.writestr(info, data)

try:
    check(package.is_file(), "packaging script does not exist")
    check(verify.is_file(), "verification script does not exist")
    with tempfile.TemporaryDirectory(prefix="phone-coder-ipa-test-") as temporary:
        temp = Path(temporary)
        app = app_fixture(temp / "direct")
        first, second = temp / "first.ipa", temp / "second.ipa"
        success(run(package, app, first))
        success(run(verify, first))
        with zipfile.ZipFile(first) as archive:
            names = set(archive.namelist())
            check("Payload/Phone Coder.app/Info.plist" in names, "missing plist")
            check("Payload/Phone Coder.app/Phone Coder" in names, "missing executable")
            check(all(name == "Payload/" or name.startswith("Payload/Phone Coder.app/")
                      for name in names), "wrong Payload layout")
            check({info.date_time for info in archive.infolist()} == {(2001, 1, 1, 0, 0, 0)},
                  "copied timestamps were not normalized")
        for path in [app, *app.rglob("*")]:
            os.utime(path, (1700000000, 1700000000))
        success(run(package, app, second))
        digest = hashlib.sha256(first.read_bytes()).hexdigest()
        check(digest == hashlib.sha256(second.read_bytes()).hexdigest(), "unstable SHA-256")
        check(Path(str(first) + ".sha256").read_text() == f"{digest}  first.ipa\n",
              "checksum sidecar does not match")
        check((app / "Phone Coder").stat().st_mtime == 1700000000,
              "packager mutated source timestamps")
        print("PASS: exact Payload layout, required files, normalized timestamps, stable SHA-256 and sidecar")

        archived = app_fixture(temp / "build.xcarchive/Products/Applications")
        archive_ipa = temp / "archive.ipa"
        success(run(package, temp / "build.xcarchive", archive_ipa))
        check(archive_ipa.read_bytes() == first.read_bytes(), "archive and direct app differ")
        # Existing outputs must never be overwritten, including the checksum.
        before = first.read_bytes()
        reject(run(package, app, first), "existing output")
        check(first.read_bytes() == before, "existing IPA changed")
        reserved = temp / "reserved.ipa"
        Path(str(reserved) + ".sha256").write_text("keep me\n")
        reject(run(package, app, reserved), "existing sidecar")
        check(not reserved.exists(), "published alongside existing sidecar")
        print("PASS: xcarchive input and existing output protection")

        # Creating staging inside the input would recurse into itself and alter
        # the source before failing. Reject this placement before any writes.
        os.utime(app, (1700000000, 1700000000))
        reject(run(package, app, app / "recursive.ipa"), "output inside source app")
        check(app.stat().st_mtime == 1700000000, "modified source while rejecting recursive output")
        print("PASS: output inside the source is refused before mutation")

        forbidden = [
            "embedded.mobileprovision", "_CodeSignature/CodeResources",
            "Frameworks/llama.framework/_CodeSignature/CodeResources",
            "model.gguf", "weights.safetensors", "model.onnx", "weights.npz",
            "ggml-tiny.bin", "model.mlmodelc/weights/data", "model.mlpackage/Manifest.json",
            "model.mlmodel", "weights.pt", "weights.pth", "weights.ckpt",
            "BundledVLM/data", "BundledVoiceModels/data", ".env", ".env.production",
            "credentials.json", "secrets.json", "AuthKey.p8", "identity.p12",
            "key.pem", "key.key", ".git/config", ".DS_Store", "debug.dSYM/data",
        ]
        for index, name in enumerate(forbidden):
            dirty = app_fixture(temp / f"forbidden-{index}")
            path = dirty / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"forbidden fixture")
            output = temp / f"forbidden-{index}.ipa"
            reject(run(package, dirty, output), name)
            check(not output.exists() and not Path(str(output) + ".sha256").exists(),
                  f"published rejected {name}")
            raw_zip(dirty, output)
            reject(run(verify, output), name)
        print("PASS: packaging and independent verification reject signing, models, credentials and forbidden metadata")

        # Build credential-like fixtures in pieces so the repository scanner does
        # not mistake test data for a checked-in credential.
        for index, secret in enumerate([b"sk-" + b"a" * 32,
                                        b"hf_" + b"b" * 25,
                                        b"-----BEGIN " + b"PRIVATE KEY-----",
                                        b'{"api_key":"fixture-private-value"}']):
            dirty = app_fixture(temp / f"secret-{index}")
            (dirty / "innocent.dat").write_bytes(b"prefix\x00" + secret)
            output = temp / f"secret-{index}.ipa"
            reject(run(package, dirty, output), "credential content")
            check(not output.exists(), "published secret")
            raw_zip(dirty, output)
            reject(run(verify, output), "credential content")
        print("PASS: credential content is rejected without exposing values")

        for missing in ["Info.plist", "Phone Coder"]:
            dirty = app_fixture(temp / ("missing-" + missing))
            (dirty / missing).unlink()
            output = temp / ("missing-" + missing + ".ipa")
            reject(run(package, dirty, output), "missing " + missing)
            check(not output.exists(), "published incomplete app")
            raw_zip(dirty, output)
            reject(run(verify, output), "missing " + missing)
        dirty = app_fixture(temp / "bad-plist")
        (dirty / "Info.plist").write_bytes(b"not a plist")
        raw_zip(dirty, temp / "bad-plist.ipa")
        reject(run(verify, temp / "bad-plist.ipa"), "malformed plist")
        dirty = app_fixture(temp / "non-executable")
        (dirty / "Phone Coder").chmod(0o644)
        raw_zip(dirty, temp / "non-executable.ipa")
        reject(run(verify, temp / "non-executable.ipa"), "non-executable binary")
        print("PASS: missing files, malformed plist and non-executable app fail closed")

        invalid = [
            ("missing-payload", lambda n: n.removeprefix("Payload/"), None),
            ("wrong-app", lambda n: n.replace("Phone Coder.app/", "Other.app/"), None),
            ("extra-root", None, ("unexpected.txt", b"x", stat.S_IFREG | 0o644)),
            ("second-app", None, ("Payload/Other.app/file", b"x", stat.S_IFREG | 0o644)),
            ("traversal", None, ("Payload/Phone Coder.app/../../escape", b"x", stat.S_IFREG | 0o644)),
            ("absolute", None, ("/Payload/Phone Coder.app/escape", b"x", stat.S_IFREG | 0o644)),
            ("backslash", None, ("Payload/Phone Coder.app/back\\slash", b"x", stat.S_IFREG | 0o644)),
            ("symlink", None, ("Payload/Phone Coder.app/link", b"/etc/passwd", stat.S_IFLNK | 0o777)),
            ("duplicate", None, ("Payload/Phone Coder.app/Assets.car", b"x", stat.S_IFREG | 0o644)),
            ("directory-data", None, ("Payload/Phone Coder.app/Hidden/", b"hidden bytes", stat.S_IFDIR | 0o755)),
            ("file-parent", None, ("Payload/Phone Coder.app/assets.CAR/hidden", b"x", stat.S_IFREG | 0o644)),
            ("case-collision", None, ("Payload/Phone Coder.app/assets.CAR", b"x", stat.S_IFREG | 0o644)),
        ]
        for name, transform, extra in invalid:
            output = temp / (name + ".ipa")
            # Duplicate ZIP member is intentional adversarial input.
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                raw_zip(app, output, transform, extra)
            reject(run(verify, output), name)
        (temp / "not-zip.ipa").write_bytes(b"invalid archive")
        reject(run(verify, temp / "not-zip.ipa"), "invalid ZIP")
        reject(run(verify, temp / "absent.ipa"), "absent IPA")
        print("PASS: malformed ZIPs, wrong layout, extra files, unsafe paths, symlinks and duplicates fail closed")

        linked = app_fixture(temp / "linked")
        (linked / "link").symlink_to(app / "Assets.car")
        reject(run(package, linked, temp / "linked.ipa"), "source symlink")
        reject(run(package, app.parent, temp / "parent.ipa"), "arbitrary source directory")
        for script in [package, verify]:
            reject(run(script), "missing arguments")
            reject(run(script, "a", "b", "c"), "extra arguments")
        if sys.platform != "darwin":
            reject(run(package, app, temp / "release.ipa", portable=False), "Linux release packaging")
        print("PASS: source symlinks, invalid input and CLI misuse rejected; Linux requires explicit test seam")
    print("All unsigned IPA regression tests passed.")
except AssertionError as error:
    print(f"FAIL: {error}", file=sys.stderr)
    sys.exit(1)
PY
