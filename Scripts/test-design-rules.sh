#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/design-rules-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

# Copy the checker so fixtures never change the working tree it normally scans.
mkdir -p "$fixture/Scripts" "$fixture/Sources/MenuBarApp/Features" "$fixture/Sources/MenuBarApp/DesignSystem"
cp "$script_dir/check-design-rules.sh" "$fixture/Scripts/"
cd "$fixture"
readonly source_file="Sources/MenuBarApp/Features/Fixture.swift"
readonly baseline="Scripts/design-rules-baseline.txt"
: > "$baseline"
checks=0

assert_check() {
    local name="$1" expected_status="$2" expected_message="$3"
    local output status=0
    output="$(GITHUB_ACTIONS='' ./Scripts/check-design-rules.sh 2>&1)" || status=$?
    if [ "$status" -ne "$expected_status" ] || [[ "$output" != *"$expected_message"* ]]; then
        printf 'FAIL: %s\nExpected exit %s and output containing: %s\nGot exit %s:\n%s\n' \
            "$name" "$expected_status" "$expected_message" "$status" "$output" >&2
        exit 1
    fi
    checks=$((checks + 1))
}

while IFS=$'\t' read -r rule code; do
    printf '%s\n' "$code" > "$source_file"
    assert_check "$code" 1 "$source_file:1: $rule:"
done <<'CASES'
native-alert	let alert = NSAlert()
native-alert	.alert("Title", isPresented: $shown) {}
confirmation-dialog	.confirmationDialog("Title", isPresented: $shown) {}
native-context-menu	.contextMenu { Text("Item") }
native-context-menu	.contextMenu(menuItems: { Text("Item") })
native-menu	Menu("Title") { Text("Item") }
native-menu	Menu { Text("Item") } label: { Text("Title") }
native-picker	Picker("Title", selection: $selection) {}
native-picker	Picker<Text, Int, Text>("Title", selection: $selection) {}
native-picker	.pickerStyle(.segmented)
native-button-style	.buttonStyle(.bordered)
native-button-style	.buttonStyle(.borderedProminent)
native-button-style	.buttonStyle(.borderless)
native-button-style	.buttonStyle(.automatic)
native-button-style	.buttonStyle(.link)
native-button-style	.buttonStyle(BorderedButtonStyle())
native-button-style	.buttonStyle(BorderedProminentButtonStyle())
native-button-style	.buttonStyle(BorderlessButtonStyle())
native-toggle-style	.toggleStyle(.switch)
native-toggle-style	.toggleStyle(.checkbox)
native-toggle-style	.toggleStyle(.button)
native-toggle-style	.toggleStyle(SwitchToggleStyle())
native-toggle-style	.toggleStyle(CheckboxToggleStyle())
native-toggle-style	.toggleStyle(ButtonToggleStyle())
rounded-text-field	.textFieldStyle(.roundedBorder)
rounded-text-field	.textFieldStyle(RoundedBorderTextFieldStyle())
animation-value	.animation(Motion.control, value: shown)
CASES

cat > "$source_file" <<'SWIFT'
AppMenu()
.appMenu {}
.appContextMenu {}
.buttonStyle(.plain)
.toggleStyle(.appSwitch)
.toggleStyle(.appCheckbox)
.textFieldStyle(.plain)
.motion(Motion.control, value: shown)
.transition(.opacity.animation(Motion.reveal))
NSOpenPanel()
NSSavePanel()
SWIFT
assert_check "shared controls and sanctioned native panels" 0 "Design rules: no new uses"

cat > "$source_file" <<'SWIFT'
// NSAlert()
    // .buttonStyle(.bordered)
.contextMenu {} // design-rules: allow, fixture exception
SWIFT
assert_check "comments and marked exceptions" 0 "Design rules: no new uses"
printf '%s\n' 'NSAlert()' >> "$source_file"
assert_check "exceptions apply only to their own line" 1 "$source_file:4: native-alert:"

: > "$source_file"
printf '%s\n' 'NSAlert()' > Sources/Example.txt
mkdir Tests
printf '%s\n' 'NSAlert()' > Tests/Example.swift
assert_check "only Swift files under Sources are checked" 0 "Design rules: no new uses"

readonly system_file="Sources/MenuBarApp/DesignSystem/Fixture.swift"
printf '%s\n' '.animation(Motion.control, value: shown)' > "$system_file"
assert_check "design system may wrap animation" 0 "Design rules: no new uses"
printf '%s\n' 'NSAlert()' >> "$system_file"
assert_check "design system still rejects native controls" 1 "$system_file:2: native-alert:"
rm "$system_file"

printf '%s\n' '.animation(Motion.control, value: shown)' > "$source_file"
cat > "$baseline" <<BASELINE
# Existing calls, with blank lines allowed.

animation-value 1 $source_file
BASELINE
assert_check "unchanged baseline count" 0 "Design rules: no new uses"
printf '%s\n' '.animation(Motion.control, value: selected)' >> "$source_file"
assert_check "baseline count cannot grow" 1 "the baseline allows 1 in this file, it has 2"

printf '%s\n' '.animation(Motion.control, value: shown)' > "$source_file"
printf 'animation-value 2 %s\n' "$source_file" > "$baseline"
assert_check "partial cleanup requires a lower baseline" 1 "Lower its count there to 1."
printf 'animation-value 1 %s\n' "$source_file" > "$baseline"
assert_check "lowered baseline matches the remaining call" 0 "Design rules: no new uses"
printf '%s\n' 'NSAlert()' >> "$source_file"
assert_check "baseline allowance is specific to a rule" 1 "$source_file:2: native-alert:"

printf '%s\n' '.motion(Motion.control, value: shown)' > "$source_file"
assert_check "removed violations require a lower baseline" 1 "Lower its count there to 0."
: > "$baseline"
assert_check "clean source with an empty baseline" 0 "Design rules: no new uses"
printf '%s\n' '.animation(Motion.control, value: shown)' > "$source_file"
assert_check "removed allowances cannot return" 1 "$source_file:1: animation-value:"

printf 'animation-value 1 %s\n' "$source_file" > "$baseline"
readonly moved_file="Sources/MenuBarApp/Features/Moved.swift"
mv "$source_file" "$moved_file"
assert_check "moved code has no allowance in its new file" 1 "$moved_file:1: animation-value:"
assert_check "moved code leaves a stale baseline entry" 1 "$source_file:1: animation-value: this file now has 0"
printf 'animation-value 1 %s\n' "$moved_file" > "$baseline"
assert_check "baseline follows a file move" 0 "Design rules: no new uses"
rm "$moved_file"
assert_check "deleted files leave stale baseline entries" 1 "$moved_file:1: animation-value: this file now has 0"
: > "$baseline"
assert_check "deleted files with their allowances removed" 0 "Design rules: no new uses"

printf 'Design-rule fixtures: %s checks passed.\n' "$checks"
