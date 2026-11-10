#!/usr/bin/env python3
"""Verify packaging against the signer-produced ZIP before update-key access."""
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / f"scripts/{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    with path.open("rb") as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
        return value.hexdigest()


def manifest(root):
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            key = str(path.relative_to(root))
            if path.is_symlink():
                result[key] = ("link", os.readlink(path))
            elif path.is_dir():
                result[key] = ("dir",)
            elif path.is_file():
                result[key] = ("file", path.stat().st_mode & 0o111, digest(path))
            else:
                raise ValueError("Unsupported file in app")
            if len(result) > 10000:
                raise ValueError("App exceeds file limit")
    return result


def verify(directory, signed_zip_digest):
    if not re.fullmatch(r"[0-9a-f]{64}", signed_zip_digest):
        raise ValueError("Invalid signer-provided digest")
    version = plistlib.loads((ROOT / "Sway/Info.plist").read_bytes())["CFBundleShortVersionString"]
    archive = directory / f"Kinara-{version}-macos-universal.zip"
    dmg = directory / f"Kinara-{version}-macos-universal.dmg"
    if set(p.name for p in directory.iterdir()) != {archive.name, dmg.name, "SHA256SUMS.txt"}:
        raise ValueError("Unexpected release files")
    for path in directory.iterdir():
        if not path.is_file() or path.is_symlink() or path.stat().st_size > 1_073_741_824:
            raise ValueError("Invalid release artifact")
    if digest(archive) != signed_zip_digest:
        raise ValueError("Packager changed the signed ZIP")
    with tempfile.TemporaryDirectory(prefix="sway-verify-downloads.") as temporary:
        work = Path(temporary)
        bundle = load("safe-app-archive").extract(archive, work / "extracted")
        subprocess.run([sys.executable, str(ROOT / "scripts/app-signing.py"), "verify", str(bundle)], check=True)
        expected = manifest(bundle)
        mount = work / "mount"
        mount.mkdir()
        subprocess.run(["/usr/bin/hdiutil", "attach", str(dmg), "-readonly", "-nobrowse", "-noautoopen",
                        "-mountpoint", str(mount), "-quiet"], check=True)
        try:
            allowed = {"Kinara.app", "Applications", "First Launch.txt", ".background.tiff", ".VolumeIcon.icns", ".DS_Store", ".fseventsd", ".Trashes"}
            if set(p.name for p in mount.iterdir()) - allowed:
                raise ValueError("Unexpected installer contents")
            for name in (".background.tiff", ".VolumeIcon.icns", ".DS_Store"):
                item = mount / name
                if item.is_symlink() or not item.is_file() or item.stat().st_size > 67_108_864:
                    raise ValueError("Invalid installer metadata")
            if (mount / "Kinara.app").is_symlink() or manifest(mount / "Kinara.app") != expected:
                raise ValueError("DMG app differs from the app signer's ZIP")
            if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
                raise ValueError("Invalid Applications shortcut")
            instructions = mount / "First Launch.txt"
            if instructions.is_symlink() or instructions.read_bytes() != (ROOT / "releases/INSTALL.txt").read_bytes():
                raise ValueError("Installer instructions differ from approved source")
            subprocess.run([sys.executable, str(ROOT / "scripts/app-signing.py"), "verify", str(mount / "Kinara.app")], check=True)
        finally:
            subprocess.run(["/usr/bin/hdiutil", "detach", str(mount), "-quiet"], check=True)
    print("ZIP digest and complete DMG app match the isolated app signer. No downloaded code was executed.")


if __name__ == "__main__":
    try:
        verify(Path(sys.argv[1]), sys.argv[2])
    except Exception:
        sys.exit("Release-download verification failed; publishing must stop.")
