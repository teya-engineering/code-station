# Releases

Releases are started manually by tagging a commit on `main` and pushing the tag:

```bash
git tag v1.2.0
git push origin v1.2.0
```

The `Release` GitHub Actions workflow first waits for the `Tests` workflow to pass on the tagged commit. It looks for the run started by that commit's push to `main`. Only then does it build, sign, and notarize the app. It creates a draft GitHub Release with generated release notes, the DMG, and its checksum.

Tag a commit whose `Tests` run passed, or one whose run is still going. The release waits for that run. Every push to `main` gets its own `Tests` run, and a later push never cancels it. If the run failed for a temporary reason, or someone cancelled it by hand, re-run it from GitHub Actions before tagging. You can also re-run the release afterwards. A commit that was never the head of a push to `main` has no such run and cannot be released.

Review the draft in GitHub Releases, then publish it. If the workflow fails for a temporary reason, run it again from GitHub Actions and select the same tag.

The build uses exactly the dependency versions in `Package.resolved`. If that file is out of date with `Package.swift`, the release fails instead of resolving newer versions. Commit an updated `Package.resolved`, then tag that commit.

## Quick builds

To hand a build to a few people without waiting on Apple, build the DMG on your own Mac and skip notarization:

```bash
./Scripts/release.sh --skip-notarization 1.2.0
```

This needs no App Store Connect API key. Gatekeeper blocks the first launch, so each person has to try to open the app once, then click **Open Anyway** in **System Settings > Privacy & Security**.

The Developer ID certificate is optional. If it is in your keychain, the app and DMG are signed with it, and macOS treats each build as the same app. If it is not, the app gets an ad-hoc signature instead. That works too, but macOS sees every build as a new app, so people are asked again for Keychain access and other permissions after each one.

Do not attach a quick build to a GitHub Release. Releases are always notarized.

## What the app expects of a release

Installed copies check this repository's latest release every five days and offer to install it. For that to work the release has to carry both assets the workflow attaches: one `.dmg`, and the `.sha256` beside it named exactly `<the dmg>.sha256`. A release without them still shows up in the app, but only as a link to the page.

The app refuses any image whose app is not signed with the `QZG8V8U2Y6` Developer ID, or whose version does not match the tag. Changing the signing team means changing `AppUpdateInstall.teamIdentifier` as well, or installed copies will reject the release.
