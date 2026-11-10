"""Disposable two-version identities; never execute fixtures or request TCC access."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("signing", ROOT / "scripts/app-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
checks = 0


def expect(condition, message):
    global checks
    assert condition, message
    checks += 1


def reject(action, message):
    try:
        action()
    except Exception:
        expect(True, message)
        return
    raise AssertionError(message)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


def keychain_lifecycle(failure=None, auto_register=False, initial=None):
    """Model a fresh runner without needing another OS or real credentials."""
    original = initial if initial is not None else ['/Users/Test User/login.keychain-db', '/tmp/keychain "quoted".keychain-db']
    current = list(original)
    events = []
    imported = False
    partitioned = False
    configured = False
    unlocked = False

    def simulated_run(*args, **kwargs):
        nonlocal current, imported, partitioned, configured, unlocked
        action = args[1] if args[0] == '/usr/bin/security' else 'codesign'
        if action == 'list-keychains':
            if '-s' not in args:
                return '\n'.join(json.dumps(item) for item in current).encode()
            action = 'restore' if list(args[5:]) == original else 'register'
        events.append(action)
        if failure == action:
            raise RuntimeError('simulated failure')
        if failure == 'interrupted' and action == 'codesign':
            raise KeyboardInterrupt()
        if action == 'create-keychain' and auto_register:
            current.append(args[-1])
        elif action == 'set-keychain-settings':
            configured = args[2:4] == ('-lut', '1800')
        elif action == 'unlock-keychain':
            unlocked = True
        elif action == 'import':
            expect('-A' not in args and args[-2:] == ('-T', '/usr/bin/codesign'), 'only codesign receives explicit private-key access')
            imported = True
        elif action == 'set-key-partition-list':
            partitioned = True
        elif action in ('register', 'restore'):
            current = list(args[5:])
        elif action == 'codesign':
            keychain = args[args.index('--keychain') + 1]
            expect(current == [keychain, *original], 'explicit search list must include the temporary chain exactly once')
            expect(configured and unlocked and imported and partitioned, 'headless signing prerequisites precede codesign')
        elif action == 'delete-keychain':
            current = [item for item in current if item != args[-1]]
        return b''

    fake_payload = {'pkcs12': base64.b64encode(b'x' * 1001).decode(), 'password': 'disposable-test-password-only'}
    with patch.object(signing, 'run', side_effect=simulated_run), patch.object(signing, 'verify') as verify:
        try:
            signing.sign(Path('/unused/Kinara.app'), fake_payload)
        except (RuntimeError, KeyboardInterrupt):
            expect(failure is not None, 'only injected failures are expected')
        else:
            expect(failure is None, 'a lifecycle failure must stop signing')
        expect(verify.call_count == (0 if failure else 1), 'verification only follows successful signing and cleanup')
    expect(events[-1] == 'restore', 'restore must be attempted even if deletion fails')
    expect(failure == 'restore' or current == original, 'original search list must be restored after success, failure, or interruption')
    expect(('delete-keychain' in events) == (failure != 'create-keychain'), 'delete only a successfully created temporary keychain')
    expect(not set(events) - {'create-keychain', 'set-keychain-settings', 'unlock-keychain', 'import',
                            'set-key-partition-list', 'register', 'codesign', 'delete-keychain', 'restore'},
           'never change the default keychain or certificate trust')


keychain_lifecycle()  # No implicit search registration, like a fresh runner.
keychain_lifecycle(auto_register=True)
keychain_lifecycle(initial=[])
for failure in ('create-keychain', 'set-keychain-settings', 'unlock-keychain', 'import',
                'set-key-partition-list', 'register', 'codesign', 'delete-keychain', 'restore', 'interrupted'):
    keychain_lifecycle(failure)

sentinel = 'PRIVATE_TEST_VALUE_MUST_NOT_APPEAR_IN_LOGS'
for diagnostic in (b'errSecInternalComponent', b'unable to build chain to self-signed root', b'unknown error'):
    result = subprocess.CompletedProcess([], 1, sentinel.encode(), diagnostic + sentinel.encode())
    with patch.object(signing.subprocess, 'run', return_value=result) as execute, patch.dict(os.environ, {signing.SECRET: sentinel, 'SPARKLE_PRIVATE_KEY': sentinel}):
        try:
            signing.run('/usr/bin/security', 'import', sentinel, '-P', sentinel)
        except signing.SigningToolError as error:
            expect(sentinel not in str(error) and 'security import failed' in str(error), 'safe diagnostics must not include arguments or raw output')
        else:
            raise AssertionError('tool failure must propagate')
        child_env = execute.call_args.kwargs['env']
        expect(signing.SECRET not in child_env and 'SPARKLE_PRIVATE_KEY' not in child_env, 'child tools must not inherit release secrets')


with tempfile.TemporaryDirectory(prefix="kinara-code-sign-tests.") as temporary:
    work = Path(temporary)
    before_keychains = run("/usr/bin/security", "list-keychains", "-d", "user")
    before_default = run("/usr/bin/security", "default-keychain", "-d", "user")
    config = work / "certificate.cnf"
    config.write_text("[req]\ndistinguished_name=dn\n[dn]\nCN=Kinara Test\n[signing]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=codeSigning\n")
    password = "disposable-signing-test-password-only"

    def identity(name):
        key, pem, cert, p12 = [work / f"{name}.{suffix}" for suffix in ("key", "pem", "cer", "p12")]
        run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2",
            "-subj", f"/CN={name}/", "-config", str(config), "-extensions", "signing", "-keyout", str(key), "-out", str(pem))
        run("/usr/bin/openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(cert))
        run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(pem), "-name", name,
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-passout", "pass:" + password, "-out", str(p12))
        return cert, {"pkcs12": base64.b64encode(p12.read_bytes()).decode(), "password": password}

    cert, payload = identity("Kinara Test")
    other_cert, other_payload = identity("Different Signer")

    def fixture(name, version):
        bundle = work / f"{name}.app"
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Resources").mkdir()
        source = work / f"{name}.c"
        source.write_text(f"int main(void) {{ return {version}; }}\n")
        run("/usr/bin/xcrun", "clang", "-arch", "arm64", "-arch", "x86_64", str(source), "-o", str(bundle / "Contents/MacOS/Kinara"))
        metadata = plistlib.loads((ROOT / "Kinara/Info.plist").read_bytes())
        metadata.update(CFBundleIdentifier=signing.IDENTIFIER, CFBundleExecutable="Kinara", CFBundleName="Kinara", CFBundlePackageType="APPL")
        if version != 1:
            metadata["CFBundleVersion"] = str(int(metadata["CFBundleVersion"]) + version)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
        (bundle / "Contents/Resources/fixture.txt").write_text(name)
        return bundle

    first, second = fixture("first", 1), fixture("second", 2)
    signing.sign(first, payload, cert)
    signing.sign(second, payload, cert)
    # sign() removes its temporary keychain before verify(). Both builds must
    # validate without any installed certificate, user trust, or private key.
    for bundle in (first, second):
        signing.verify(bundle, cert)
        expect(True, "both versions validate against the same pinned requirement")
    expect((first / "Contents/MacOS/Kinara").read_bytes() != (second / "Contents/MacOS/Kinara").read_bytes(), "fixtures contain different executable code")
    expect(signing.requirement(cert) not in signing.requirement(other_cert), "unrelated signer has a different requirement")
    reject(lambda: signing.verify(first, other_cert), "wrong certificate must fail")
    impostor = fixture("impostor", 1)
    signing.sign(impostor, other_payload, other_cert)
    reject(lambda: signing.verify(impostor, cert), "same bundle ID under another signer must fail")
    weakened = fixture("weakened-requirement", 1)
    original_requirement = signing.requirement
    try:
        signing.requirement = lambda *args: 'identifier "com.trackpadcontrol.app"'
        signing.sign(weakened, payload, cert)
    finally:
        signing.requirement = original_requirement
    reject(lambda: signing.verify(weakened, cert), "even the correct signer must declare a certificate-bound requirement")
    (second / "Contents/Resources/fixture.txt").write_text("tampered")
    reject(lambda: signing.verify(second, cert), "tampered resources must fail")
    unsigned = fixture("ad-hoc", 1)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
        "--requirements", '=designated => identifier "com.trackpadcontrol.app"', "--entitlements", str(ROOT / "Kinara/Kinara.entitlements"), str(unsigned))
    reject(lambda: signing.verify(unsigned, cert), "identifier-only ad-hoc workaround must fail")
    reject(lambda: signing.sign(unsigned, other_payload, cert), "private identity must match the public certificate pin")
    env = os.environ.copy()
    env["CI"] = "true"
    env.pop(signing.SECRET, None)
    missing = subprocess.run(["python3", str(ROOT / "scripts/app-signing.py"), "sign", str(unsigned)], env=env, capture_output=True)
    expect(missing.returncode != 0, "CI may never fall back to a local/ad-hoc identity")
    sentinel = "PRIVATE_TEST_VALUE_MUST_NOT_APPEAR_IN_LOGS"
    env[signing.SECRET] = sentinel
    malformed = subprocess.run(["python3", str(ROOT / "scripts/app-signing.py"), "sign", str(unsigned)], env=env, capture_output=True)
    expect(malformed.returncode != 0 and sentinel.encode() not in malformed.stdout + malformed.stderr, "malformed secret fails without credential disclosure")
    expect(run("/usr/bin/security", "list-keychains", "-d", "user") == before_keychains, "temporary keychains must leave the search list unchanged")
    expect(run("/usr/bin/security", "default-keychain", "-d", "user") == before_default, "temporary keychains must leave the default keychain unchanged")

print(f"{checks} app-identity assertions passed with disposable keys and two different universal builds. No fixture ran; no TCC or trust settings changed.")
