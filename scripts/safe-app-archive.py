#!/usr/bin/env python3
"""Extract a bounded app ZIP as data, rejecting traversal and link escapes."""
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import unicodedata
import zipfile


def extract(archive, destination):
    destination = Path(destination)
    if destination.exists():
        raise ValueError("Extraction destination must not already exist")
    if Path(archive).is_symlink() or Path(archive).stat().st_size > 1_073_741_824:
        raise ValueError("Invalid archive")
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        if not 1 <= len(entries) <= 10000 or sum(i.file_size for i in entries) > 1_073_741_824:
            raise ValueError("Archive exceeds limits")
        seen, kinds, links = set(), {}, {}
        for entry in entries:
            name = entry.filename.rstrip("/")
            path = PurePosixPath(name)
            if (not name or name.startswith("/") or "\\" in name or ":" in name
                    or any(ord(c) < 32 for c in name) or ".." in path.parts
                    or str(path) != name or path.parts[0] != "Kinara.app"):
                raise ValueError("Unsafe archive path")
            folded = unicodedata.normalize("NFC", name).casefold()
            if folded in seen or entry.flag_bits & 1 or entry.compress_type not in (0, 8):
                raise ValueError("Duplicate, encrypted, or unsupported entry")
            seen.add(folded)
            mode = entry.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise ValueError("Unsupported archive file type")
            if mode & (stat.S_ISUID | stat.S_ISGID):
                raise ValueError("Special permission bits are forbidden")
            kinds[name] = "link" if kind == stat.S_IFLNK else "dir" if entry.is_dir() else "file"
            if kinds[name] == "link":
                if entry.file_size > 4096:
                    raise ValueError("Oversized link")
                target = source.read(entry).decode("utf-8")
                if not target or target.startswith("/") or "\\" in target or any(ord(c) < 32 for c in target):
                    raise ValueError("Unsafe link target")
                # Lexical containment, before anything is written to disk.
                resolved = os.path.normpath(str(path.parent / target))
                if resolved != "Kinara.app" and not resolved.startswith("Kinara.app/"):
                    raise ValueError("Link escapes app")
                links[name] = target
        if kinds.get("Kinara.app", "dir") != "dir":
            raise ValueError("App root must be a directory")
        for name in kinds:
            for parent in PurePosixPath(name).parents:
                if kinds.get(str(parent), "dir") != "dir":
                    raise ValueError("Entries may not be extracted through files or links")
        destination.mkdir(mode=0o700, parents=False)
        # Create only regular files/directories first, never follow ZIP links.
        for entry in entries:
            name = entry.filename.rstrip("/")
            output = destination / name
            if kinds[name] == "link":
                continue
            if kinds[name] == "dir":
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with source.open(entry) as data, output.open("xb") as target:
                    shutil.copyfileobj(data, target)
                output.chmod((entry.external_attr >> 16) & 0o777 or 0o644)
        for name, target in links.items():
            output = destination / name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.symlink_to(target)
        root = (destination / "Kinara.app").resolve(strict=True)
        for name in links:
            resolved = (destination / name).resolve(strict=True)
            if resolved != root and root not in resolved.parents:
                raise ValueError("Resolved link escapes app")
    return destination / "Kinara.app"


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("Expected archive and new destination")
        extract(*sys.argv[1:])
        print("App archive extracted as data; paths and links validated. No app code executed.")
    except Exception:
        sys.exit("Unsafe or invalid app archive; extraction refused.")
