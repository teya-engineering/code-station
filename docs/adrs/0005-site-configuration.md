# ADR 0005 - Site configuration

## Context

Some settings belong to one organisation, not to the app: environments, the sign-in provider for APIs, starter requests, MCP presets, a skills marketplace and shortcuts. The app is open source, so none of that can live in the code.

## Decision

Organisation settings live in one optional JSON file, `site-defaults.json`. Nothing is compiled in. A plain checkout builds an app with all of these sections empty, and the rest of the app works as normal.

The file can be imported on first launch (from a local file or a Git repository), changed later in Settings, or folded into the app bundle at build time. The app reads the first valid file it finds and shows a warning for any it cannot read.

Hostnames, client IDs and repository URLs for an organisation go in this file, never in Swift. Tests pass in the settings they need instead of reading the current file, so they pass on a checkout with no site file.

The [site configuration guide](../site-configuration.md) covers the load order, import options and every field.

## Consequences

- Any organisation can use the app by writing its own file. Teya's lives in a separate repository.
- A new organisation-specific setting needs a field in the file, the example file and the guide, not a constant in code.
