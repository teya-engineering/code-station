# ADR 0006 - Own design system

## Context

Native AppKit and SwiftUI controls draw with the system's look. They cannot be fully styled, so a dialog, menu or picker from the system looks like part of another program. The app also has many screens, built by many people and agents, that must look and move as one.

## Decision

The app draws all of its own controls from a shared design system in `Sources/MenuBarApp/DesignSystem`:

- Colour, type, spacing, corners, heights, shadows and timing come from shared tokens. Feature views never hold raw values.
- Dialogs, menus, segmented choices, switches, checkboxes, buttons and text fields all have in-app versions. System-styled controls are not used.
- The one exception is the file chooser (`NSOpenPanel` and `NSSavePanel`), because it belongs to the system.
- Everything a person can see or touch has motion from shared curves, and falls back to a plain fade under Reduce Motion.

The [design system guide](../design-system.md) lists the tokens and shared parts and says when to use each.

## Consequences

- The app looks and moves the same on every screen, and in light and dark mode.
- A missing control must be added to the design system and its guide first, then used. This costs more than reaching for a system control.
- Views that still hold raw values are moved onto the tokens when they are touched.
