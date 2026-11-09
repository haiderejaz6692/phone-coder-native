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
import struct
import sys
import unicodedata
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
# Public Mach-O/signing formats: Apple's mach-o/{loader,fat}.h and cs_blobs.h.
# Include byte-swapped 32/64-bit headers and both universal table widths.
THIN_MAGICS = {
    b"\xfe\xed\xfa\xce": (">", 28), b"\xce\xfa\xed\xfe": ("<", 28),
    b"\xfe\xed\xfa\xcf": (">", 32), b"\xcf\xfa\xed\xfe": ("<", 32),
}
FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
    b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32),
}
SIGNATURE_BLOB = re.compile(
    rb"(?:\xfa\xde\x0c[\xc0\xc1\x02]|\xfa\xde\x0b[\x01\x02])(.{4})", re.DOTALL
)

def require(condition, message):
    if not condition:
        raise ValueError(message)

def forbidden(part):
    lower = collision_key(part)
    return (lower in FORBIDDEN_NAMES or lower.endswith(FORBIDDEN_SUFFIXES)
            or lower.startswith((".env", "._", "credentials.", "secrets.")))

def collision_key(path):
    # Conservatively reject canonical Unicode aliases on Apple filesystems.
    # Normalize again after folding because folding can introduce combining marks.
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", path).casefold())

def inspect_macho(stream, length):
    def read_at(offset, size):
        require(0 <= offset <= length and 0 <= size <= length - offset, "truncated Mach-O data")
        stream.seek(offset)
        data = stream.read(size)
        require(len(data) == size, "truncated Mach-O data")
        return data

    def inspect_slice(offset, size):
        require(size >= 4, "truncated Mach-O slice")
        magic = read_at(offset, 4)
        require(magic in THIN_MAGICS, "universal slice is not a thin Mach-O")
        order, header_size = THIN_MAGICS[magic]
        require(size >= header_size, "truncated Mach-O header")
        count, command_bytes = struct.unpack(order + "II", read_at(offset + 16, 8))
        require(command_bytes <= size - header_size and count <= command_bytes // 8,
                "invalid Mach-O load command bounds")
        position = offset + header_size
        end = position + command_bytes
        for _ in range(count):
            require(position + 8 <= end, "truncated Mach-O load command")
            command, command_size = struct.unpack(order + "II", read_at(position, 8))
            require(command_size >= 8 and command_size % 4 == 0 and command_size <= end - position,
                    "invalid Mach-O load command size")
            # LC_CODE_SIGNATURE and LC_DYLIB_CODE_SIGN_DRS are never unsigned,
            # including empty/stale commands or an unexpected LC_REQ_DYLD bit.
            require((command & 0x7fffffff) not in (0x1d, 0x2b), "embedded Mach-O code-signature command")
            position += command_size
        require(position == end, "unaccounted Mach-O load command bytes")

    magic = read_at(0, min(4, length))
    if magic in THIN_MAGICS:
        inspect_slice(0, length)
    elif magic in FAT_MAGICS:
        order, record_size = FAT_MAGICS[magic]
        count = struct.unpack(order + "I", read_at(4, 4))[0]
        require(0 < count <= (length - 8) // record_size, "invalid universal Mach-O table")
        table_end = 8 + count * record_size
        slices = []
        for index in range(count):
            record = read_at(8 + index * record_size, record_size)
            if record_size == 32:
                _, _, offset, size, alignment, reserved = struct.unpack(order + "IIQQII", record)
                require(reserved == 0, "invalid universal Mach-O reserved field")
            else:
                _, _, offset, size, alignment = struct.unpack(order + "IIIII", record)
            require(table_end <= offset <= length and 4 <= size <= length - offset,
                    "invalid universal Mach-O slice bounds")
            require(alignment < 64 and offset % (1 << alignment) == 0,
                    "invalid universal Mach-O slice alignment")
            slices.append((offset, size))
        previous_end = table_end
        for offset, size in sorted(slices):
            require(offset >= previous_end, "overlapping universal Mach-O slices")
            inspect_slice(offset, size)
            previous_end = offset + size
    else:
        return False
    return True

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
            key = collision_key(name.rstrip("/"))
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
        files = {collision_key(name) for name, info in entries.items() if not info.is_dir()}
        for name, info in entries.items():
            # Catch file/directory collisions even when ZIP omits directory entries.
            for parent in PurePosixPath(name).parents:
                require(collision_key(str(parent)) not in files, "file used as ZIP directory")
            if info.is_dir():
                continue
            with archive.open(info) as stream:
                macho = inspect_macho(stream, info.file_size)
                stream.seek(0)
                overlap = b""
                first = True
                consumed = 0
                while True:
                    chunk = stream.read(1024 * 1024)
                    if not chunk:
                        break
                    require(not (first and chunk.startswith(b"GGUF")), "model weights in bundle")
                    require(not SECRET.search(overlap + chunk), "possible credential content in bundle")
                    if macho:
                        # Also reject orphaned signature blobs left behind by a
                        # removed command. Length must describe data in this member.
                        for match in SIGNATURE_BLOB.finditer(overlap + chunk):
                            blob_offset = consumed - len(overlap) + match.start()
                            blob_length = int.from_bytes(match.group(1), "big")
                            require(not 8 <= blob_length <= info.file_size - blob_offset,
                                    "embedded Mach-O code-signature blob")
                    consumed += len(chunk)
                    overlap = chunk[-512:]
                    first = False
    print("Verified unsigned IPA layout and forbidden-content policy.")
except (OSError, ValueError, KeyError, TypeError, EOFError, RuntimeError,
        zipfile.BadZipFile, NotImplementedError) as error:
    sys.exit(f"error: unsigned IPA verification failed: {error}")
PY
