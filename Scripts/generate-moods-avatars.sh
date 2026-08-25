#!/bin/bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly resource_dir="${script_dir}/../Sources/MenuBarApp/Resources"
readonly download_dir="$(mktemp -d /private/tmp/code-station-moods.XXXXXX)"
readonly avatar_count=64

for ((index = 1; index <= avatar_count; index++)); do
    number="$(printf '%02d' "${index}")"
    curl --fail --silent --show-error --location \
        "https://api.dicebear.com/10.x/moods/png?seed=code-station-moods-${number}&size=128" \
        --output "${download_dir}/avatar-moods-${number}.png"
done

for ((index = 1; index <= avatar_count; index++)); do
    number="$(printf '%02d' "${index}")"
    install -m 0644 \
        "${download_dir}/avatar-moods-${number}.png" \
        "${resource_dir}/avatar-moods-${number}.png"
done

echo "Generated ${avatar_count} Moods avatars in ${resource_dir}"
echo "Downloaded files remain in ${download_dir}"
