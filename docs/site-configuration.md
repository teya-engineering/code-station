# Site configuration

Site configuration keeps the parts of Code Station that belong to one organisation outside the app's source code. A configuration can provide environments, API access, starter requests, MCP presets, a skills marketplace, and command shortcuts.

Every section is optional, and so is the file itself. Without one, the app uses its built-in staging and production environments, with no saved requests, MCP presets, marketplace, or shortcuts. Everything else works as normal.

[`site-defaults.example.json`](../site-defaults.example.json) is a complete example with placeholder values.

## Import a configuration

The first-launch wizard offers three choices:

- Choose a JSON file from the Mac.
- Enter a Git repository URL. The repository must contain `site-defaults.json`, `teya-defaults.json`, or exactly one JSON file in its root. Code Station clones it with the user's existing Git access, so the same flow works for a private repository that Git can already read.
- Skip the step and use the defaults built into the app.

Teya users can enter [`github.com/saltpay/code-station-settings`](https://github.com/saltpay/code-station-settings) to load the shared Teya configuration.

An import is a snapshot. Code Station validates the file and copies it to:

```text
~/Library/Application Support/com.teya.code-station/site-defaults.json
```

Settings > Advanced shows the current environments, API access, starter requests, MCP presets, skills marketplace, and shortcuts in typed forms. It offers the same local-file and Git import options at any time. Loading a file only previews it. You can then reset any combination of those six parts while leaving every unchecked part unchanged.

The JSON on that screen is read-only and generated from the current configuration. It can be copied or exported as a reset file, so the UI and the exported document cannot drift apart.

## Load order

Code Station reads the first configuration that can be parsed:

1. The path in `$CODE_STATION_SITE_DEFAULTS`
2. A saved external configuration path
3. `~/Library/Application Support/com.teya.code-station/site-defaults.json`
4. `site-defaults.json` inside the app bundle

If a file cannot be read or parsed, the app warns you and tries the next location. If no valid fallback is available, it starts without site defaults and keeps the warning visible.

`site-defaults.json` in the repository root is ignored by Git, so working settings do not end up in a commit.

## Build a configured app

`./build-app.sh` can include a settings file in the bundle it builds. This produces an app that is already configured and ready to distribute to a team.

The script uses `site-defaults.json` from the repository root unless `SITE_DEFAULTS` names another file:

```bash
./build-app.sh
SITE_DEFAULTS=/path/to/team-defaults.json ./build-app.sh
```

A `swift run` development build has no bundle in which to include the file, so use the first-launch import, Settings > Advanced, or `$CODE_STATION_SITE_DEFAULTS` instead.

## Field reference

| Field | What it does |
| --- | --- |
| `environments` | Defines the deployments the organisation runs. Each entry has a `name`, an optional display `title`, and optional `danger: true`. Dispatch replaces `{{env}}` in request URLs with the selected environment's name. Dangerous environments ask for confirmation before each API request and tell troubleshooting sessions to keep every check read-only. MCP servers can also be tagged with one of these names. A server without a matching tag is available in every environment. When this field is absent or empty, Code Station uses `staging` and `production`. |
| `dispatch.oauth` | Defines the identity provider used by configured API environments. `grant` is `authorizationCodePKCE` or `clientCredentials`. The remaining fields are `authURL`, `tokenURL`, `clientID`, `scope`, and `callbackURL`. Each environment keeps its own credentials in the app. |
| `dispatch.requests` | Defines the saved requests available on a fresh install. Each request has a `name`, `url`, and optional `method`. `{{env}}` in the URL is replaced with the selected environment's name. |
| `mcp.presets` | Defines reusable servers shown when adding an MCP server. Each preset has a unique `name`, optional display `title` and `environment`, and exactly one connection: a stdio `command` with optional `args` and `env`, or a remote `url` with optional `type` and `headers`. An empty environment variable or header value is requested when the preset is added, so the shared file can define required credentials without storing them. |
| `skills` | Defines the marketplace shown by the Skills screen. It contains the display `name`, the `marketplace` name used by the agent CLIs, and the source `repository`. |
| `shortcuts` | Defines command shortcuts available on a fresh install. Each entry has a `name` and `command`. These shortcuts run from the user's home folder because the configuration does not belong to a specific project. Users can add their own global or project shortcuts, which are stored locally and are not overwritten by this file. |

## Secrets

Do not put client secrets, access tokens, passwords, or other personal credentials in a site configuration. OAuth client secrets and tokens stay in the macOS Keychain.

MCP presets can declare an environment variable or header with an empty value. Code Station asks the user for that value when the preset is added instead of storing it in the shared file.
