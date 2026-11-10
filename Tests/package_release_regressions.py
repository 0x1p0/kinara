"""Packaging starts from a clean checkout and rejects untrusted inputs.

No build cache, signing key, network, app execution, or disk-image mount is used.
The deliberately unsigned fixture must reach verification, then fail closed.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
checks = 0


def expect(condition, message):
    global checks
    assert condition, message
    checks += 1


with tempfile.TemporaryDirectory(prefix="kinara clean packaging ") as temporary:
    parent = Path(temporary)
    metadata = plistlib.loads((ROOT / "Kinara/Info.plist").read_bytes())
    version = metadata["CFBundleShortVersionString"]
    metadata.update(CFBundleIdentifier="com.trackpadcontrol.app", CFBundleExecutable="Kinara")
    archive = parent / "unsigned fixture.zip"
    with zipfile.ZipFile(archive, "w") as output:
        output.writestr("Kinara.app/Contents/Info.plist", plistlib.dumps(metadata))
        output.writestr("Kinara.app/Contents/MacOS/Kinara", b"Deliberately invalid; never execute this fixture.")
    malformed = parent / "malformed.zip"
    malformed.write_bytes(b"Not a ZIP archive.")

    def checkout(name):
        project = parent / name
        for relative in ("scripts/package-release.sh", "scripts/release-version.sh",
                         "scripts/safe-app-archive.py", "scripts/app-signing.py",
                         "scripts/verify-runtime.sh", "scripts/signing/Kinara.cer", "Kinara/Info.plist"):
            target = project / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        notes = project / f"releases/v{version}.md"
        notes.parent.mkdir()
        notes.write_text("Disposable packaging test notes.\n")
        expect(not (project / "build").exists(), "each fixture must start without a build directory")
        return project

    def package(project, input_archive=archive, tag=None):
        environment = {key: value for key, value in os.environ.items()
                       if key not in {"KINARA_APP_SIGNING_IDENTITY", "SPARKLE_PRIVATE_KEY"}}
        environment.update(CI="true", KINARA_DEFER_UPDATE_SIGNING="1")
        # Intentionally invoke from elsewhere, as well as using paths with spaces.
        return subprocess.run(["/bin/bash", str(project / "scripts/package-release.sh"),
                               tag or f"v{version}", str(input_archive)],
                              cwd=parent, env=environment, capture_output=True, text=True, timeout=30)

    project = checkout("fresh checkout")
    result = package(project)
    expect(result.returncode != 0, "unsigned app must be rejected")
    expect("mktemp:" not in result.stderr, "fresh runner must create its staging parent before mktemp")
    expect("App archive extracted as data" in result.stdout, "clean packaging must reach archive extraction")
    expect("App identity verification/signing failed" in result.stderr, "untrusted app must stop at identity verification")
    expect(len(list((project / "build").glob("SignedPackage.*/extracted/Kinara.app"))) == 1,
           "staging must live under this checkout's build directory")
    expect(not list((project / "build").glob("ReleasePackage.*")), "rejected app must never reach artifact packaging")
    expect(not (project / "build/releases").exists(), "rejected app must not produce release outputs")

    project = checkout("invalid archive")
    result = package(project, malformed)
    expect(result.returncode != 0 and "mktemp:" not in result.stderr, "bad archive must fail without a staging error")
    expect(not list((project / "build").glob("ReleasePackage.*")), "bad archive must not reach artifact packaging")

    project = checkout("wrong version")
    result = package(project, tag="v0.0.0")
    expect(result.returncode != 0 and "does not match app version" in result.stderr, "mismatched version must fail")
    expect(not (project / "build").exists(), "version rejection must not create staging")

    project = checkout("missing notes")
    (project / f"releases/v{version}.md").unlink()
    result = package(project)
    expect(result.returncode != 0 and "Missing release notes" in result.stderr, "missing notes must fail")
    expect(not (project / "build").exists(), "missing notes must not create staging")

    project = checkout("existing release")
    release = project / f"build/releases/v{version}"
    release.mkdir(parents=True)
    sentinel = release / "keep.txt"
    sentinel.write_text("Existing output must survive.")
    result = package(project)
    expect(result.returncode != 0 and "Release output already exists" in result.stderr, "existing output must be rejected")
    expect(sentinel.read_text() == "Existing output must survive.", "existing output must remain unchanged")
    expect(not list((project / "build").glob("SignedPackage.*")), "overwrite guard must run before extraction")

print(f"{checks} clean-checkout packaging assertions passed. No keys, caches, app execution, or network used.")
