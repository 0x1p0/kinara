# Persistent app identity

`Sway.cer` is the public DER certificate for release app signing. Its subject is
`CN=Sway`. It is safe to publish; it contains no private key, personal name, or
email. It is a self-issued, code-signing-only root (path length zero), not an
Apple Developer ID certificate. Users do not need to install this certificate
or change their trust settings. It does not remove Gatekeeper's warning.

The private PKCS#12 identity and wrapping password are stored as one protected
item in the maintainer's login Keychain:

- Service: `com.sway.app-signing`
- Account: `sway-application-0x1p0`
- Label: `Sway persistent app signing identity`

GitHub Actions receives the same identity only through `SWAY_APP_SIGNING_IDENTITY`
in the approval-protected `release` environment. It is not a repository-level
secret. Never print it, commit it, or regenerate it during a build. Keep an
encrypted offline backup through a secure credential-management process.

The signer unlocks a disposable Keychain, permits `/usr/bin/codesign` to use
its imported private key, and explicitly adds that Keychain to the user's
search list while signing. `codesign --keychain` selects the identity but does
not replace the certificate-chain search list. The signer deletes its temporary
Keychain and restores the original search list on both success and failure;
it never changes the default Keychain or certificate trust. See
[GitHub's macOS runner setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
Workflow errors report only fixed diagnostic categories, never private values,
command arguments, or raw security-tool output.

The designated requirement pins both `com.trackpadcontrol.app` and this exact
certificate. Release verification checks every executable architecture and
compares the embedded certificate bytes with this file. Do not replace this
with a bundle-identifier-only requirement: anyone could imitate that identity.
The certificate is valid until September 2046; plan an explicitly tested
migration before expiry. A lost/compromised key or changed certificate may
require users to grant permissions again. This self-signed identity has no
Apple-managed revocation service.

This key is separate from `SPARKLE_PRIVATE_KEY`, which authenticates the update
feed and ZIP. Local release packaging reads both identities from Keychain;
`SWAY_DEFER_UPDATE_SIGNING=1` skips only the update signature, not app signing.
`scripts/build.sh` remains a key-free ad-hoc development build and is not a
permission-preserving release. Never replace the installed release with it
when testing permission continuity.

To inspect the public identity:

```sh
openssl x509 -inform DER -in scripts/signing/Sway.cer -noout -subject -issuer -dates -fingerprint -sha256
codesign --display -r - /Applications/Sway.app
python3 scripts/app-signing.py verify build/Sway.app
```

The two-version signing regression uses disposable certificates and never
launches its fixtures. A real TCC test is distinct: install the first persistent
release, grant Accessibility once, install a newer release signed by this same
identity into the same location, and confirm gestures work without editing the
Accessibility entry. Do not reset TCC, remove the permission entry, switch to an
ad-hoc build, or install a certificate during that test.

# Optional: Developer ID and notarization

The self-signed identity above keeps Accessibility permission across updates,
but it cannot remove Gatekeeper's "Apple could not verify Sway" warning. Only a
**Developer ID Application** certificate plus Apple notarization can. That
needs an Apple Developer Program membership, which only the maintainer can
enroll in.

`scripts/notarize.sh` signs a copy of `build/Sway.app` with Developer ID
(Sparkle's nested code first), submits it to Apple's notary service, staples
the ticket, and checks it with `spctl`. It never touches the input app or the
release workflow. Instructions are at the top of the script.

Before switching releases over, weigh the trade-off:

- **One more Accessibility grant.** A Developer ID signature has a different
  designated requirement than `CN=Sway`, so macOS treats the first Developer ID
  build as a new app. Users re-enable Sway in Accessibility once; after that,
  Developer ID builds keep the permission as reliably as the current identity.
- **Update signing is unchanged.** Sparkle's EdDSA key is separate from app
  signing, so existing installs keep receiving verified updates.
- **Entitlements stay the same.** Once every release uses Developer ID and
  Sparkle is re-signed with the same team, the library-validation exception
  can be removed; update `scripts/verify-runtime.sh` and its tests together.
- **CI.** Wiring this into the release workflow means a third protected secret
  (the Developer ID identity) and notary credentials in the `release`
  environment, with the same approval gates as today.
