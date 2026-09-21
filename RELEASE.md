# Releases

Releases are started manually by tagging a commit on `main` and pushing the tag:

```bash
git tag v1.2.0
git push origin v1.2.0
```

The `Release` GitHub Actions workflow then builds, signs, and notarizes the app. It creates a draft GitHub Release with generated release notes, the DMG, and its checksum.

Review the draft in GitHub Releases, then publish it. If the workflow fails for a temporary reason, run it again from GitHub Actions and select the same tag.

## What the app expects of a release

Installed copies check this repository's latest release every five days and offer to install it. For that to work the release has to carry both assets the workflow attaches: one `.dmg`, and the `.sha256` beside it named exactly `<the dmg>.sha256`. A release without them still shows up in the app, but only as a link to the page.

The app refuses any image whose app is not signed with the `QZG8V8U2Y6` Developer ID, or whose version does not match the tag. Changing the signing team means changing `AppUpdateInstall.teamIdentifier` as well, or installed copies will reject the release.
