#!/usr/bin/env python3
"""Pinned, persistent app identity. Never execute code from the app being signed."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
CERTIFICATE = ROOT / "scripts/signing/Kinara.cer"
IDENTIFIER = "com.trackpadcontrol.app"
SERVICE = "com.kinara.app-signing"
ACCOUNT = "kinara-0x1p0"
SECRET = "KINARA_APP_SIGNING_IDENTITY"


class SigningToolError(RuntimeError):
    """Only fixed, credential-free diagnostics may reach a workflow log."""

    def __init__(self, arguments, result):
        tool = Path(arguments[0]).name
        operation = ""
        if tool == "security" and arguments[1] in {
            "list-keychains", "create-keychain", "set-keychain-settings", "unlock-keychain",
            "import", "set-key-partition-list", "delete-keychain", "find-generic-password",
        }:
            operation = " " + arguments[1]
        diagnostic = (result.stdout + result.stderr).lower()
        reason = "tool returned an error; no raw output was logged"
        for marker, explanation in (
            (b"unable to build chain", "certificate chain could not be resolved"),
            (b"cssmerr_tp_not_trusted", "certificate chain was not accepted"),
            (b"user interaction is not allowed", "key access requires an unavailable prompt"),
            (b"specified item could not be found", "signing identity was not found"),
            (b"errsecinternalcomponent", "Security framework rejected signing (errSecInternalComponent)"),
            (b"mac verification failed", "PKCS#12 could not be unlocked"),
            (b"resource fork", "bundle contains unsupported extended attributes"),
        ):
            if marker in diagnostic:
                reason = explanation
                break
        super().__init__(f"{tool}{operation} failed (exit {result.returncode}): {reason}")


def run(*arguments, include_diagnostics=False, **kwargs):
    # Never echo commands, environment values, or raw tool diagnostics: import
    # commands contain a short-lived wrapping password. Classify known errors
    # using fixed strings so CI remains diagnosable without leaking credentials.
    environment = {k: v for k, v in os.environ.items() if k not in (SECRET, "SPARKLE_PRIVATE_KEY")}
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=environment, **kwargs)
    if result.returncode:
        raise SigningToolError(arguments, result)
    return result.stdout + result.stderr if include_diagnostics else result.stdout


def requirement(certificate=CERTIFICATE, identifier=IDENTIFIER):
    fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
    return f'identifier "{identifier}" and certificate root = H"{fingerprint}"'


def verify(bundle, certificate=CERTIFICATE, identifier=IDENTIFIER):
    metadata = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    if metadata.get("CFBundleIdentifier") != identifier or metadata.get("CFBundleExecutable") != "Kinara":
        raise RuntimeError("Unexpected app identity or executable")
    expected = requirement(certificate, identifier)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--all-architectures",
        "-R", "=" + expected, str(bundle))
    architectures = run("/usr/bin/lipo", "-archs", str(bundle / "Contents/MacOS/Kinara")).decode().split()
    if not architectures or set(architectures) - {"arm64", "x86_64"}:
        raise RuntimeError("Unexpected executable architectures")
    with tempfile.TemporaryDirectory(prefix="kinara-public-cert.") as temporary:
        for arch in architectures:
            # Checking the signature alone does not guarantee the embedded DR
            # is restrictive. Require the pinned DR in EVERY executable slice.
            lines = run("/usr/bin/codesign", "--display", "--arch", arch,
                        "-r", "-", str(bundle), include_diagnostics=True).decode().splitlines()
            if f"designated => {expected}" not in lines:
                raise RuntimeError("App does not declare the pinned persistent identity")
            prefix = str(Path(temporary) / f"{arch}-")
            run("/usr/bin/codesign", "--display", "--arch", arch,
                "--extract-certificates=" + prefix, str(bundle))
            if Path(prefix + "0").read_bytes() != certificate.read_bytes():
                raise RuntimeError("App certificate does not match the repository pin")
    run("/bin/bash", str(ROOT / "scripts/verify-runtime.sh"), str(bundle))


def sign(bundle, payload, certificate=CERTIFICATE, identifier=IDENTIFIER):
    if not isinstance(payload, dict) or set(payload) != {"pkcs12", "password"}:
        raise RuntimeError("Invalid signing identity format")
    archive = base64.b64decode(payload["pkcs12"], validate=True)
    if not 1000 < len(archive) < 65536 or not isinstance(payload["password"], str) or len(payload["password"]) < 24:
        raise RuntimeError("Invalid signing identity data")
    # --keychain restricts identity lookup, but codesign still uses the user
    # search list to construct its certificate chain. Do not rely on creation
    # implicitly registering the keychain: that differs across runner setups.
    # Restore the original list even on failure. Never change the default
    # keychain, certificate trust, installed apps, or TCC permissions.
    with tempfile.TemporaryDirectory(prefix="kinara-app-signing.") as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        p12 = directory / "identity.p12"
        p12.write_bytes(archive)
        p12.chmod(0o600)
        keychain = directory / "signing.keychain-db"
        password = secrets.token_urlsafe(32)
        original_keychains = shlex.split(run("/usr/bin/security", "list-keychains", "-d", "user").decode())
        created = False
        try:
            run("/usr/bin/security", "create-keychain", "-p", password, str(keychain))
            created = True
            run("/usr/bin/security", "set-keychain-settings", "-lut", "1800", str(keychain))
            run("/usr/bin/security", "unlock-keychain", "-p", password, str(keychain))
            run("/usr/bin/security", "import", str(p12), "-k", str(keychain),
                "-P", payload["password"], "-T", "/usr/bin/codesign")
            run("/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:",
                "-s", "-k", password, str(keychain))
            run("/usr/bin/security", "list-keychains", "-d", "user", "-s", str(keychain), *original_keychains)
            fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest()
            run("/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain),
                "--timestamp=none", "--options", "runtime", "--identifier", identifier,
                "--requirements", "=designated => " + requirement(certificate, identifier),
                "--entitlements", str(ROOT / "Kinara/Kinara.entitlements"), str(bundle))
        finally:
            try:
                if created:
                    run("/usr/bin/security", "delete-keychain", str(keychain))
            finally:
                run("/usr/bin/security", "list-keychains", "-d", "user", "-s", *original_keychains)
    verify(bundle, certificate, identifier)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["sign", "verify"])
    parser.add_argument("bundle", type=Path)
    args = parser.parse_args()
    if not args.bundle.is_dir() or args.bundle.is_symlink():
        raise RuntimeError("Expected a staged app directory, not a link")
    actual = plistlib.loads((args.bundle / "Contents/Info.plist").read_bytes())
    expected = plistlib.loads((ROOT / "Kinara/Info.plist").read_bytes())
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "SUFeedURL", "SUPublicEDKey"):
        if actual.get(key) != expected.get(key):
            raise RuntimeError("App metadata does not match the approved release source")
    if args.operation == "sign":
        encoded = os.environ.get(SECRET)
        if encoded is None:
            if os.environ.get("CI") == "true":
                raise RuntimeError("Protected app-signing secret is missing; no ad-hoc fallback")
            encoded = run("/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT,
                          "-w", str(Path.home() / "Library/Keychains/login.keychain-db")).decode()
        sign(args.bundle, json.loads(encoded))
    else:
        verify(args.bundle)
    print("Persistent Kinara identity, certificate pin, and Hardened Runtime verified.")


if __name__ == "__main__":
    try:
        main()
    except SigningToolError as error:
        sys.exit(f"App identity verification/signing failed: {error}. Nothing was published.")
    except Exception:
        # JSON/base64/import errors may contain credential data. Do not expose
        # exception strings or tracebacks from a process holding the identity.
        sys.exit("App identity verification/signing failed. Check the pinned certificate and protected credentials; nothing was published.")
