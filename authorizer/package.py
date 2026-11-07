#!/usr/bin/env python3
"""Build a reproducible Lambda zip: same source in -> byte-identical zip out.

Fixed timestamps and file modes mean Terraform's source_code_hash only changes when the code changes,
regardless of machine, OS or checkout time.

Usage: python package.py <output.zip> <file> [<file> ...]
"""
import sys
import zipfile
from pathlib import Path

FIXED_TIME = (1980, 1, 1, 0, 0, 0)  # earliest timestamp the zip format supports


def build(out: Path, files: list[Path]) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for f in sorted(files, key=lambda p: p.name):
            info = zipfile.ZipInfo(f.name, date_time=FIXED_TIME)  # flat: handler.py at zip root
            info.external_attr = 0o644 << 16                       # -rw-r--r--
            info.compress_type = zipfile.ZIP_DEFLATED
            # Normalise CRLF -> LF so a Windows checkout produces the same zip as Linux.
            zf.writestr(info, f.read_bytes().replace(b"\r\n", b"\n"))


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    build(Path(sys.argv[1]), [Path(p) for p in sys.argv[2:]])
