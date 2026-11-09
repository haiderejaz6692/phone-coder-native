#!/usr/bin/env bash
# Package an app built with CODE_SIGNING_ALLOWED=NO; never sign or strip it.
set -euo pipefail
if [[ "$#" != 2 ]]; then
  echo "usage: $0 <archive-or-app-path> <output.ipa>" >&2
  exit 64
fi
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_path="$1"
output_path="$2"
[[ "$output_path" == *.ipa ]] || { echo 'error: output must end in .ipa' >&2; exit 64; }
if [[ "$(uname -s)" != Darwin && "${PHONE_CODER_PORTABLE_TEST:-0}" != 1 ]]; then
  echo 'error: release packaging requires macOS ditto; PHONE_CODER_PORTABLE_TEST=1 is for fake-bundle tests only' >&2
  exit 1
fi
output_directory="$(cd "$(dirname "$output_path")" && pwd -P)"
output_path="$output_directory/$(basename "$output_path")"
source_directory="$(cd "$source_path" && pwd -P)"
case "$output_directory/" in
  "$source_directory/"*)
    echo 'error: output directory must be outside the source app/archive' >&2
    exit 1
    ;;
esac
if [[ -e "$output_path" || -L "$output_path" || -e "$output_path.sha256" || -L "$output_path.sha256" ]]; then
  echo 'error: output IPA or checksum already exists' >&2
  exit 1
fi
work_directory="$(mktemp -d "$output_directory/.phone-coder-ipa.XXXXXX")"
trap 'rm -rf "$work_directory"' EXIT

python3 - "$source_path" "$work_directory" <<'PY'
import os
from pathlib import Path
import shutil
import stat
import sys

try:
    source, stage = map(Path, sys.argv[1:])
    if source.is_symlink():
        raise ValueError("source must not be a symlink")
    if source.suffix == ".xcarchive":
        applications = source / "Products/Applications"
        if any(path.is_symlink() for path in [source / "Products", applications]):
            raise ValueError("archive application path must not be a symlink")
        apps = list(applications.iterdir())
        if len(apps) != 1 or apps[0].name != "Phone Coder.app":
            raise ValueError("archive must contain exactly Phone Coder.app")
        source = apps[0]
    if source.name != "Phone Coder.app" or not source.is_dir() or source.is_symlink():
        raise ValueError("expected Phone Coder.app or an xcarchive containing it")
    payload = stage / "Payload"
    destination = payload / "Phone Coder.app"
    destination.mkdir(parents=True)
    # Copy in sorted order, without xattrs/resource forks, ownership, ACLs or
    # source timestamps. Reject links and special files instead of following.
    for current, directories, files in os.walk(source, followlinks=False):
        directories.sort()
        files.sort()
        relative = Path(current).relative_to(source)
        for name in directories + files:
            path = Path(current) / name
            mode = path.lstat().st_mode
            copied = destination / relative / name
            if stat.S_ISDIR(mode):
                copied.mkdir()
                copied.chmod(0o755)
            elif stat.S_ISREG(mode):
                shutil.copyfile(path, copied)
                copied.chmod(0o755 if mode & 0o111 else 0o644)
            else:
                raise ValueError("bundle contains a symlink or special file")
    # ZIP's DOS timestamps are local time. TZ=UTC below makes this invariant
    # across hosts; 2001-01-01 is representable by both ditto and Python ZIP.
    for path in [payload, destination, *destination.rglob("*")]:
        os.utime(path, (978307200, 978307200))
    payload.chmod(0o755)
    destination.chmod(0o755)
except (OSError, ValueError) as error:
    sys.exit(f"error: cannot stage unsigned app: {error}")
PY

export TZ=UTC
if [[ "$(uname -s)" == Darwin ]]; then
  # This is the release path, even when the portable test variable is set.
  (cd "$work_directory" && ditto -c -k --sequesterRsrc --keepParent Payload result.ipa)
else
  # Explicit opt-in for regression tests on Ubuntu; not an Apple release path.
  python3 - "$work_directory" <<'PY'
from pathlib import Path
import sys
import zipfile

stage = Path(sys.argv[1])
with zipfile.ZipFile(stage / "result.ipa", "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path in sorted((stage / "Payload").rglob("*")):
        archive.write(path, path.relative_to(stage).as_posix())
PY
fi
bash "$script_directory/verify_unsigned_ipa.sh" "$work_directory/result.ipa"
python3 - "$work_directory" "$output_path" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

stage, output = map(Path, sys.argv[1:])
digest = hashlib.sha256()
with (stage / "result.ipa").open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
checksum = stage / "result.sha256"
checksum.write_text(f"{digest.hexdigest()}  {output.name}\n", encoding="utf-8")
# Same-filesystem exclusive links publish only verified bytes, never overwrite.
published = False
try:
    os.link(stage / "result.ipa", output)
    published = True
    os.link(checksum, str(output) + ".sha256")
except OSError as error:
    if published:
        output.unlink()
    sys.exit(f"error: cannot publish IPA/checksum: {error}")
print(f"Packaged verified unsigned IPA: {output}")
PY
