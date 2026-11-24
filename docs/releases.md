# Releases

To release, draft a new release on GitHub, type a new tag such as `v1.2.0` targeting `main`, write the notes, and publish it. Publishing creates the tag, and the tag starts the `Release` GitHub Actions workflow, which builds the app and attaches the DMG and its checksum to that release.

The workflow first waits for the `Tests` workflow to pass on the tagged commit. It looks for the run started by that commit's push to `main`. Only then does it build, sign, and notarize the app. Someone with access to the `release` environment has to approve that step.

Until the files are attached, the workflow marks the release as a pre-release. GitHub leaves pre-releases out of "latest", so installed copies do not see a release with nothing to install. Once the files are on it, the workflow makes it a full release again. A version with a suffix, such as `v1.2.0-beta.1`, stays a pre-release.

Other ways in work too:

- Push a tag by itself (`git tag v1.2.0 && git push origin v1.2.0`). The workflow makes and publishes the release, with generated notes, once the files are built.
- Save a draft release first, then push its tag. A draft does not create its tag, so nothing runs until the tag is pushed. The workflow attaches the files to the draft and leaves it a draft, for you to publish when you are ready.

Tag a commit whose `Tests` run passed, or one whose run is still going. The release waits for that run. Every push to `main` gets its own `Tests` run, and a later push never cancels it. If the run failed for a temporary reason, or someone cancelled it by hand, re-run it from GitHub Actions before tagging. You can also re-run the release afterwards. A commit that was never the head of a push to `main` has no such run and cannot be released.

If the workflow fails, the release stays a pre-release with no files. Fix the cause, then run the workflow again from GitHub Actions and select the same tag. A re-run replaces any files the last try left behind. The workflow never replaces the files on a published release that already has them.

The Tests workflow and release build use exactly the dependency versions in `Package.resolved`. If that file is out of date with `Package.swift`, they fail instead of resolving newer versions. Commit an updated `Package.resolved`, then tag that commit.

## Checking a download

The workflow attests each DMG: GitHub keeps a signed record that this repository's `Release` workflow built that file, at that commit. To check a downloaded copy:

```bash
gh attestation verify TeyaCodeStation-1.2.0.dmg \
  -R teya-engineering/code-station \
  --signer-workflow teya-engineering/code-station/.github/workflows/release.yml
```

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
