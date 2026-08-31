# Publishing Teya Code Station

Distribution outside the App Store: **Developer ID Application + hardened runtime + notarization + DMG**. Without this, anyone who downloads it sees *"cannot be opened because Apple cannot check it for malicious software"*.

Team ID: `QZG8V8U2Y6` · Bundle ID: `com.teya.code-station`

## 0. What is already done

- [x] **Developer ID Application - Teya Services Limited** certificate, valid until 2031-09-01
- [x] Certificate downloaded and installed in the Keychain
- [x] App Store Connect API key in the right place (`~/private_keys/AuthKey_2VM7JH4JUA.p8`)
- [x] First manual release (1.0.0, notarized and checked with quarantine on 2026-08-31)
- [ ] CI workflow

## 1. Install the certificate

On the certificate page, click **Download**, then double-click the `.cer`. Check it:

```bash
security find-identity -v -p codesigning
```

This has to show up:

```
1) ABC123… "Developer ID Application: Teya Services Limited (QZG8V8U2Y6)"
```

If the certificate shows up but `codesign` fails with *"no identity found"*, the private key is not on this machine. The private key only exists on the Mac where you generated the `.certSigningRequest`. In that case, export the certificate and key pair from there as a `.p12`.

## 2. App Store Connect API key

Keep the `.p8` outside the repository (for example `~/private_keys/AuthKey_XXXXXXXXXX.p8`). You need three things: the file, the **Key ID** and the **Issuer ID** (App Store Connect → Users and Access → Integrations → Keys).

## 3. Files to add to the repo

```
Resources/CodeStation.entitlements   # hardened runtime, minimal
Scripts/release.sh                   # build → sign → notarize → DMG
.github/workflows/release.yml        # the same, in CI, per tag
```

## 4. Manual release (do this one first)

```bash
export AC_API_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
export AC_API_KEY_ID=XXXXXXXXXX
export AC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

./Scripts/release.sh 1.0.0
```

The script does this, in order:

1. `./build-app.sh release`
2. writes the version into `Info.plist`
3. re-signs everything with Developer ID, `--options runtime --timestamp` (replaces the ad-hoc signature left by `build-app.sh`)
4. `notarytool submit --wait` on the `.app` → `stapler staple`
5. builds the DMG with a shortcut to `/Applications`, signs it, notarizes it and staples it
6. checks it with `spctl` and writes the SHA-256

It usually takes 5-15 minutes, almost all of it waiting on Apple.

### The test that matters

**Do not test on the Mac you built on** - it has no quarantine. Send the DMG to another machine (or fake the flag):

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" TeyaCodeStation-1.0.0.dmg
```

Then open it as usual. It has to open with no warnings and without right-click → Open.

## 5. Automate it

Secrets to create in Settings → Secrets and variables → Actions:

| Secret | How to get it |
|---|---|
| `MACOS_CERTIFICATE_P12` | Keychain Access → certificate + key → Export `.p12` → `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | the password you set when exporting the `.p12` |
| `AC_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `AC_API_KEY_ID` | Key ID (10 characters) |
| `AC_API_ISSUER_ID` | Issuer ID (UUID) |

Then:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The workflow creates a **draft release** with the DMG and the `.sha256`. You review it and publish it.

## 6. Update the page

https://teya-engineering.github.io/code-station/ currently tells people to clone the repo and run `./build-app.sh`. After the first release, the main path becomes:

- a download button pointing at `https://github.com/teya-engineering/code-station/releases/latest`
- requirements: macOS 14+
- building from source moves into a "for contributors" section

Note: `build-app.sh` injects `site-defaults.json` into the bundle. Decide whether the public build ships with defaults or with no configuration at all - whatever goes inside the `.app` is signed and handed to everyone.

## Common problems

| Symptom | Cause |
|---|---|
| `notarytool` returns `Invalid` | run `xcrun notarytool log <id> --key … --key-id … --issuer …`; it is nearly always a binary without hardened runtime or without a secure timestamp |
| App only crashes once it is signed | a missing entitlement - read the comments in `CodeStation.entitlements` and add them one at a time |
| `The signature does not include a secure timestamp` | `--timestamp` was missing, or the machine had no network while signing |
| `spctl` says `rejected` even though it is notarized | you forgot `stapler staple`, or you tested a file with no quarantine |
| Keychain error in CI | `security set-key-partition-list` is missing |
