#!/usr/bin/env bash
# Real ZIP/filesystem checks against disposable fake app bundles; no Apple build.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repository_root" "$@" <<'PY'
import hashlib
import os
from pathlib import Path
import plistlib
import stat
import struct
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

def thin_macho(bits=64, order="<", signing_command=None, signature_blob=True):
    # Independently encoded Mach-O header, UUID command and optional signature.
    # These are structural fixtures, not runnable machine code.
    header_size = 32 if bits == 64 else 28
    uuid = struct.pack(order + "II", 0x1b, 24) + bytes(range(16))
    blob = struct.pack(">III", 0xfade0cc0, 12, 0) if signature_blob and signing_command else b""
    commands = uuid
    if signing_command is not None:
        commands += struct.pack(order + "IIII", signing_command, 16, header_size + 40, len(blob))
    header = struct.pack(order + "IIIIIII", 0xfeedfacf if bits == 64 else 0xfeedface,
                         0x0100000c if bits == 64 else 12, 0, 2,
                         2 if signing_command is not None else 1, len(commands), 0)
    if bits == 64:
        header += struct.pack(order + "I", 0)
    return header + commands + blob

def universal_macho(slices, bits=32, order=">"):
    # Two independently aligned architecture slices; exercise all fat formats.
    offset = 256
    records, payload = [], b""
    for index, data in enumerate(slices):
        cpu = 0x0100000c if index == 0 else 0x01000007
        record = (struct.pack(order + "IIQQII", cpu, 0, offset, len(data), 8, 0)
                  if bits == 64 else struct.pack(order + "IIIII", cpu, 0, offset, len(data), 8))
        records.append(record)
        payload += data
        padding = (-len(data)) % 256
        payload += b"\x00" * padding
        offset += len(data) + padding
    header = struct.pack(order + "II", 0xcafebabf if bits == 64 else 0xcafebabe, len(slices))
    table = header + b"".join(records)
    return table + b"\x00" * (256 - len(table)) + payload

def check_overlapping_signature(temp):
    dirty = app_fixture(temp / "overlapping-signature")
    # A false magic interprets the real magic as its impossible length. The
    # genuine superblob begins four bytes later and must still be evaluated.
    data = thin_macho() + struct.pack(">I", 0xfade0cc0) + struct.pack(">III", 0xfade0cc0, 12, 0)
    (dirty / "Phone Coder").write_bytes(data)
    output = temp / "overlapping-signature.ipa"
    raw_zip(dirty, output)
    reject(run(verify, output), "overlapping embedded Mach-O signature")
    packaged = temp / "overlapping-signature-packaged.ipa"
    reject(run(package, dirty, packaged), "packaged overlapping embedded Mach-O signature")
    check(not packaged.exists() and not Path(str(packaged) + ".sha256").exists(),
          "published overlapping embedded Mach-O signature")
    print("PASS: overlapping signature blob candidates fail closed in verification and packaging")

try:
    check(package.is_file(), "packaging script does not exist")
    check(verify.is_file(), "verification script does not exist")
    if sys.argv[2:] == ["--overlapping-signature"]:
        with tempfile.TemporaryDirectory(prefix="phone-coder-ipa-overlap-test-") as temporary:
            check_overlapping_signature(Path(temporary))
        sys.exit(0)
    check(not sys.argv[2:], "unknown regression-test selection")
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
            "credential\u017f.json", "weights.\u017fafetensors",
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

        # ZIP can preserve both spellings even when an Apple filesystem would
        # map them to the same path. Test member and ancestor collision keys.
        for label, descendant in [("members", ""), ("file-parent", "/child"),
                                  ("directory-parent", "/child/")]:
            output = temp / f"unicode-{label}.ipa"
            raw_zip(app, output,
                    lambda name: name.replace("Assets.car", "Caf\u00e9"),
                    ("Payload/Phone Coder.app/cafe\u0301" + descendant,
                     b"" if descendant.endswith("/") else b"collision",
                     (stat.S_IFDIR | 0o755) if descendant.endswith("/") else (stat.S_IFREG | 0o644)))
            reject(run(verify, output), "NFC/NFD " + label + " collision")
        print("PASS: Unicode-equivalent entries and file/parent paths fail closed")

        signed_machos = []
        for bits in [32, 64]:
            for order, endian_name in [("<", "le"), (">", "be")]:
                label = f"{bits}-{endian_name}"
                unsigned_thin = thin_macho(bits, order)
                unsigned_fat = universal_macho([unsigned_thin, thin_macho()], bits, order)
                clean = app_fixture(temp / ("unsigned-macho-" + label))
                (clean / "Phone Coder").write_bytes(unsigned_thin)
                (clean / "Frameworks/llama.framework/llama").write_bytes(unsigned_fat)
                output = temp / ("unsigned-macho-" + label + ".ipa")
                raw_zip(clean, output)
                success(run(verify, output))
                success(run(package, clean, temp / ("unsigned-macho-packaged-" + label + ".ipa")))
                signed_machos.append(("thin-" + label, thin_macho(bits, order, 0x1d)))
                signed_machos.append(("fat-second-slice-" + label,
                                      universal_macho([unsigned_thin, thin_macho(64, "<", 0x1d)],
                                                      bits, order)))
        signed_machos += [
            ("command-without-blob", thin_macho(signing_command=0x1d, signature_blob=False)),
            ("dylib-code-sign-drs", thin_macho(signing_command=0x2b)),
            ("orphan-superblob", thin_macho() + struct.pack(">III", 0xfade0cc0, 12, 0)),
            ("orphan-old-blob", thin_macho() + struct.pack(">II", 0xfade0b02, 8)),
        ]
        # A signature header crossing the content scanner's read boundary must
        # still be rejected after a removed signing command.
        unsigned = thin_macho()
        signed_machos.append(("boundary-superblob", unsigned + b"\x00" * (1024 * 1024 - 5 - len(unsigned))
                              + struct.pack(">III", 0xfade0cc0, 12, 0)))
        members = ["Phone Coder", "Frameworks/llama.framework/llama", "Resources/opaque.dat"]
        for index, (label, data) in enumerate(signed_machos):
            dirty = app_fixture(temp / ("signed-macho-" + label))
            member = dirty / members[index % len(members)]
            member.parent.mkdir(parents=True, exist_ok=True)
            member.write_bytes(data)
            output = temp / ("signed-macho-" + label + ".ipa")
            raw_zip(dirty, output)
            reject(run(verify, output), "embedded Mach-O signature: " + label)
            packaged = temp / ("signed-macho-packaged-" + label + ".ipa")
            reject(run(package, dirty, packaged), "packaged embedded Mach-O signature: " + label)
            check(not packaged.exists() and not Path(str(packaged) + ".sha256").exists(),
                  "published signed Mach-O: " + label)
        print("PASS: unsigned Mach-O formats accepted; embedded signing commands/blobs rejected in every member and universal slice")

        check_overlapping_signature(temp)

        malformed_machos = [
            ("truncated-thin", b"\xcf\xfa\xed\xfe"),
            ("truncated-fat", b"\xca\xfe\xba\xbe\x00\x00\x00\x02"),
            ("zero-command-size", struct.pack("<IIIIIIIIII", 0xfeedfacf, 0, 0, 2, 1, 8, 0, 0, 0x1b, 0)),
            ("hidden-command", struct.pack("<IIIIIIIIII", 0xfeedfacf, 0, 0, 2, 0, 8, 0, 0, 0x1b, 8)),
            ("slice-out-of-range", struct.pack(">IIIIIII", 0xcafebabe, 1, 0, 0, 4096, 32, 0)),
        ]
        for label, data in malformed_machos:
            output = temp / ("malformed-macho-" + label + ".ipa")
            raw_zip(app, output, extra=("Payload/Phone Coder.app/opaque.dat", data, stat.S_IFREG | 0o644))
            reject(run(verify, output), "malformed Mach-O: " + label)
        print("PASS: malformed Mach-O headers, load commands and universal slice bounds fail closed")

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
