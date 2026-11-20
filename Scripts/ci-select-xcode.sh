#!/bin/bash
# Points the rest of a CI job at the Xcode named in .xcode-version, instead of
# the image's default. A Swift release can reject or crash on code that another
# release builds, and the SDK decides some AppKit behaviour, so Tests and
# Release must use the same Xcode that developers use.
set -euo pipefail

version="$(tr -d '[:space:]' < .xcode-version)"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "::error file=.xcode-version::not an Xcode version: $version"
    exit 1
fi

xcode="/Applications/Xcode_$version.app"
if [ ! -d "$xcode" ]; then
    shopt -s nullglob
    installed=(/Applications/Xcode_*.app)
    echo "::error file=.xcode-version::Xcode $version is not on this image; it has: ${installed[*]:-none}"
    exit 1
fi

echo "DEVELOPER_DIR=$xcode/Contents/Developer" >> "$GITHUB_ENV"
