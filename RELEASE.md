# Releases

Releases are started manually by tagging a commit on `main` and pushing the tag:

```bash
git tag v1.2.0
git push origin v1.2.0
```

The `Release` GitHub Actions workflow then builds, signs, and notarizes the app. It creates a draft GitHub Release with generated release notes, the DMG, and its checksum.

Review the draft in GitHub Releases, then publish it. If the workflow fails for a temporary reason, run it again from GitHub Actions and select the same tag.
