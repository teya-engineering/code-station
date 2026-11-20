#!/bin/bash
# Fails when Swift code under Sources uses something the UI and Motion rules in
# CLAUDE.md forbid: native controls that draw with the system's chrome, and
# .animation(_:value:) in place of .motion(_:value:).
#
#   ./Scripts/check-design-rules.sh
#
# It matches one line at a time, so a call split over several lines slips past.
# It is a backstop for review, not a replacement for it.
#
# A line that really needs an exception carries a comment saying why:
#   .contextMenu { ... } // design-rules: allow, <the reason>
#
# Uses that predate a rule are listed in Scripts/design-rules-baseline.txt, as a
# count per file. A file may not go over its count. Once a file has fewer uses,
# lower its count, so the old uses cannot come back.
set -euo pipefail

cd "$(dirname "$0")/.."
readonly baseline="Scripts/design-rules-baseline.txt"
readonly design_system="Sources/MenuBarApp/DesignSystem/"

hits="$(mktemp)"
trap 'rm -f "$hits"' EXIT

# One rule per line, fields separated by tabs:
#   id, where it applies (all, or features = everything outside DesignSystem),
#   an extended regular expression, and what to use instead.
# The patterns stay within POSIX ERE, so BSD grep on a Mac and GNU grep on
# Linux read them the same way.
readonly rules='native-alert	all	NSAlert|\.alert[[:space:]]*\(	Show an in-app Dialog through DialogPresenter (DesignSystem/Controls/Dialog.swift).
confirmation-dialog	all	\.confirmationDialog[[:space:]]*\(	Show a Dialog through DialogPresenter; to confirm a deletion use Dialog.impact.
native-context-menu	all	\.contextMenu[[:space:]]*[({]	Use .appContextMenu (DesignSystem/Controls/ContextMenu.swift).
native-menu	all	(^|[^A-Za-z0-9_.])Menu[[:space:]]*[({]	Use .appMenu, backed by MenuPresenter (DesignSystem/Controls/ContextMenu.swift).
native-picker	all	(^|[^A-Za-z0-9_.])Picker[[:space:]]*[(<]|\.pickerStyle[[:space:]]*\(	Lay out ChoicePills in an HStack (DesignSystem/Controls/Choices.swift), or use .appMenu for a dropdown.
native-button-style	all	\.buttonStyle[[:space:]]*\([[:space:]]*\.(bordered|borderedProminent|borderless|automatic|link)|(^|[^A-Za-z0-9_])(Bordered|BorderedProminent|Borderless)ButtonStyle[[:space:]]*\(	Use .buttonStyle(.plain) with a hand-styled label and a .contentShape.
native-toggle-style	all	\.toggleStyle[[:space:]]*\([[:space:]]*\.(switch|checkbox|button)|(^|[^A-Za-z0-9_])(Switch|Checkbox|Button)ToggleStyle[[:space:]]*\(	Use .toggleStyle(.appSwitch) or .toggleStyle(.appCheckbox) (DesignSystem/Controls/Toggles.swift).
rounded-text-field	all	\.textFieldStyle[[:space:]]*\([[:space:]]*\.roundedBorder|(^|[^A-Za-z0-9_])RoundedBorderTextFieldStyle	Use .textFieldStyle(.plain) on a Theme.field background with a Theme.border stroke.
animation-value	features	\.animation[[:space:]]*\(.*,[[:space:]]*value:	Use .motion(_:value:), which turns the motion off when Reduce Motion is on (DesignSystem/Motion/Motion.swift).'

report() { # file line message
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        printf '::error file=%s,line=%s::%s\n' "$1" "$2" "$3"
    else
        printf '%s:%s: %s\n' "$1" "$2" "$3"
    fi
}

failed=0
while IFS=$'\t' read -r id scope pattern advice; do
    status=0
    grep -rEn --include='*.swift' -e "$pattern" Sources > "$hits" || status=$?
    if [ "$status" -gt 1 ]; then
        echo "error: grep could not run the pattern for $id" >&2
        exit 2
    fi

    # Drop comment lines, marked exceptions and, for features rules, the design
    # system itself, which is where the sanctioned wrappers live.
    filtered="$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' "$hits" | grep -v 'design-rules: allow' || true)"
    if [ "$scope" = features ]; then
        filtered="$(printf '%s\n' "$filtered" | grep -vF "$design_system" || true)"
    fi
    printf '%s\n' "$filtered" | sed '/^$/d' > "$hits"

    # Each line out is "over <file> <count> <allowed>" or "under <file> ...".
    verdicts="$(awk -v id="$id" '
        FILENAME == ARGV[1] { if ($1 == id) allowed[$3] = $2; next }
        { file = $0; sub(/:.*/, "", file); seen[file]++ }
        END {
            for (f in seen) if (seen[f] > allowed[f] + 0) print "over", f, seen[f], allowed[f] + 0
            for (f in allowed) if (seen[f] + 0 < allowed[f]) print "under", f, seen[f] + 0, allowed[f]
        }' <(grep -vE '^[[:space:]]*(#|$)' "$baseline") "$hits")"

    while read -r verdict file count allowed; do
        [ -n "$verdict" ] || continue
        failed=1
        if [ "$verdict" = over ]; then
            note=""
            [ "$allowed" -gt 0 ] && note=" (the baseline allows $allowed in this file, it has $count)"
            grep -F "$file:" "$hits" | while IFS=: read -r path line _; do
                [ "$path" = "$file" ] && report "$path" "$line" "$id: $advice$note"
            done
        else
            report "$file" 1 "$id: this file now has $count, fewer than the $allowed in $baseline. Lower its count there to $count."
        fi
    done <<< "$verdicts"
done <<< "$rules"

if [ "$failed" -ne 0 ]; then
    echo "Design rules broken; see CLAUDE.md (UI and Motion) and docs/design-system.md." >&2
    exit 1
fi
echo "Design rules: no new uses of forbidden native controls or .animation(_:value:)."
