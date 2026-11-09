#!/usr/bin/env bash
# Inspect ZIP members directly: never extract untrusted archive paths.
set -euo pipefail
if [[ "$#" != 1 ]]; then
  echo "usage: $0 <ipa>" >&2
  exit 64
fi
python3 - "$1" <<'PY'
from pathlib import PurePosixPath
import plistlib
import re
import stat
import sys
import zipfile

APP = "Payload/Phone Coder.app/"
FORBIDDEN_SUFFIXES = (
    ".mobileprovision", ".p8", ".p12", ".pfx", ".pem", ".key", ".cer",
    ".gguf", ".ggml", ".safetensors", ".onnx", ".npz", ".npy", ".bin",
    ".mlmodel", ".mlmodelc", ".mlpackage", ".pt", ".pth", ".ckpt",
    ".h5", ".hdf5", ".tflite", ".ipa", ".xcarchive", ".dsym",
)
FORBIDDEN_NAMES = {
    "_codesignature", "embedded.mobileprovision", "bundledvlm", "bundledvoicemodels",
    ".git", ".svn", ".ds_store", "exportoptions.plist", "credentials", "secrets",
    "id_rsa", "id_ed25519", "tokenizer.json", "vocab.json", "merges.txt",
}
# Do not print matches: verification errors must never disclose credential data.
SECRET = re.compile(
    rb"AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9_]{30,}|"
    rb"github_pat_[A-Za-z0-9_]{50,}|glpat-[A-Za-z0-9_-]{20,}|"
    rb"hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|"
    rb"-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----|"
    rb'''(?i:(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)["']?\s*[:=]\s*["']?[A-Za-z0-9_+/=-]{8,})'''
)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def forbidden(part):
    lower = part.lower()
    return (lower in FORBIDDEN_NAMES or lower.endswith(FORBIDDEN_SUFFIXES)
            or lower.startswith((".env", "._", "credentials.", "secrets.")))

try:
    with zipfile.ZipFile(sys.argv[1]) as archive:
        entries = {}
        folded = set()
        for info in archive.infolist():
            name = info.filename
            parts = name.rstrip("/").split("/")
            require(name and "\\" not in name and not any(ord(c) < 32 for c in name)
                    and all(part not in ("", ".", "..") for part in parts), "unsafe ZIP path")
            require(name in ("Payload/", APP) or name.startswith(APP), "wrong Payload/app layout")
            key = name.rstrip("/").casefold()
            require(key not in folded, "duplicate or case-colliding ZIP entry")
            folded.add(key)
            require(not any(forbidden(part) for part in parts), "forbidden bundle contents")
            mode = info.external_attr >> 16
            kind = stat.S_IFMT(mode)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR), "symlink or special ZIP member")
            require(not info.is_dir() or kind != stat.S_IFREG, "invalid ZIP directory")
            require(info.is_dir() or kind != stat.S_IFDIR, "invalid ZIP file")
            require(not info.is_dir() or info.file_size == 0, "ZIP directory contains hidden data")
            require(not info.flag_bits & 1, "encrypted ZIP member")
            entries[name] = info

        plist_name = APP + "Info.plist"
        require(plist_name in entries and not entries[plist_name].is_dir(), "missing Info.plist")
        require(0 < entries[plist_name].file_size <= 1024 * 1024, "invalid Info.plist size")
        plist = plistlib.loads(archive.read(plist_name))
        require(isinstance(plist, dict), "invalid Info.plist")
        executable = plist.get("CFBundleExecutable")
        require(isinstance(executable, str) and executable not in ("", ".", "..")
                and "/" not in executable and "\\" not in executable, "invalid CFBundleExecutable")
        executable_name = APP + executable
        require(executable_name in entries and not entries[executable_name].is_dir(), "missing executable")
        require(entries[executable_name].file_size > 0 and
                (entries[executable_name].external_attr >> 16) & 0o111, "app binary is not executable")
        files = {name.casefold() for name, info in entries.items() if not info.is_dir()}
        for name, info in entries.items():
            if info.is_dir():
                continue
            # Catch file/directory collisions even when ZIP omits directory entries.
            for parent in PurePosixPath(name).parents:
                require(str(parent).casefold() not in files, "file used as ZIP directory")
            with archive.open(info) as stream:
                overlap = b""
                first = True
                while True:
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        break
                    require(not (first and chunk.startswith(b"GGUF")), "model weights in bundle")
                    require(not SECRET.search(overlap + chunk), "possible credential content in bundle")
                    overlap = chunk[-512:]
                    first = False
    print("Verified unsigned IPA layout and forbidden-content policy.")
except (OSError, ValueError, KeyError, TypeError, EOFError, RuntimeError,
        zipfile.BadZipFile, NotImplementedError) as error:
    sys.exit(f"error: unsigned IPA verification failed: {error}")
PY
