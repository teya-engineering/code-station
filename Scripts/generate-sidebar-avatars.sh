#!/bin/bash

set -euo pipefail

readonly script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly resource_dir="${script_dir}/../Sources/MenuBarApp/Resources/SidebarAvatars"
readonly avatar_count=64

# Styles without an animation component are listed here so the download skips the
# variant they would reject.
readonly still_styles=(stripes weave bottts-neutral)

readonly all_styles=(
    squircles planets shapes blobs waves sprouts stripes landscape
    weave critters moods bottts-neutral
)

styles=("$@")
if [[ ${#styles[@]} -eq 0 ]]; then
    styles=("${all_styles[@]}")
fi

for style in "${styles[@]}"; do
    animation="&animationVariant=medium"
    for still in "${still_styles[@]}"; do
        if [[ "${still}" == "${style}" ]]; then
            animation=""
        fi
    done

    for ((index = 1; index <= avatar_count; index++)); do
        number="$(printf '%02d' "${index}")"
        curl --fail --silent --show-error --location \
            "https://api.dicebear.com/10.x/${style}/svg?seed=code-station-sidebar-${style}-${number}${animation}" \
            --output "${resource_dir}/sidebar-avatar-${style}-${number}.svg"
    done

    echo "Generated ${avatar_count} ${style} avatars"
done
