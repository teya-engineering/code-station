# Teya Conductor

[![Contributing](https://img.shields.io/badge/Contributing-guide-2ea44f.svg?logo=github)](CONTRIBUTING.md)

Teya Conductor is a macOS app for running Codex and Claude Code across local projects. It brings the conversation, project files, Git state, and a terminal into one window, while each coding agent continues to use its own CLI and account.

![Teya Conductor showing fictional projects and an agent session](docs/images/teya-conductor.png)

## Main features

### Projects, workspaces, and sessions

- Add any local folder as a project and keep its agent sessions together.
- Group related projects into a reusable workspace. One project is the lead working directory and the others are attached to the same conversation.
- Run a session in the project folder when you want changes to land there immediately.
- Run a session in an isolated Git worktree when you want its own checkout and branch. Independent worktree sessions can run at the same time without editing the same files.
- Choose Codex or Claude Code for each session, along with its model, reasoning effort, and access settings.
- Resume saved conversations after relaunching the app and review old sessions before removing them.

### Built-in tools

- Configure MCP servers and register them with Codex, Claude Code, or both.
- Install and update agent skills from your organisation's marketplace.
- Save and send HTTP requests with environment variables, path and query parameters, headers, request bodies, and OAuth secrets and tokens stored in the macOS Keychain.
- Inspect running Docker containers and stop them when needed.
- Save, edit, run, and stop shell-command shortcuts while inspecting their output. A local Qwen model through `llama-server` is included by default.
- Start a guided troubleshooting session with project context, attachments, environment safeguards, and configured observability tools.

## Build and run

### Requirements

- macOS 14 or later
- Xcode 16 or another Swift 6 toolchain
- Git
- At least one supported coding agent installed and signed in: `codex` or `claude`

### Build the app

Clone the repository and create a double-clickable app bundle:

```bash
git clone git@github.com:example/teya-conductor.git
cd teya-conductor
./build-app.sh
open "build/Teya Conductor.app"
```

The build script creates an ad-hoc signed release bundle at `build/Teya Conductor.app`. You can move that bundle to `/Applications` for normal use.

For a quick development run without creating an app bundle:

```bash
swift run --disable-sandbox
```

The app bundle is recommended for regular use and is required for the Start at Login setting.

## Site configuration

A few features point at things that belong to your organisation rather than to the app: the identity provider your APIs sign in against, the calls worth starting from, your Grafana instances, and the skills marketplace your agents install from. None of that is in the code. It is all data, in a settings file the app reads at startup.

Every section is optional, and so is the file itself. Without it the app runs with blank API environments, no saved requests, no Grafana presets, and the Skills screen reporting that no marketplace is set up. Everything else works as normal.

Two settings files are kept here:

- `site-defaults.example.json` is a blank-slate example. Copy it and fill in your own values.
- `teya-defaults.json` is Teya's own setup, which is what Teya builds of this app use.

### Set it up

Copy the example, then edit it:

```bash
cp site-defaults.example.json site-defaults.json
```

The app reads the first of these that exists:

1. The path in `$CONDUCTOR_SITE_DEFAULTS`
2. `~/Library/Application Support/com.teya.conductor/site-defaults.json`
3. `site-defaults.json` inside the app bundle

Put your file in the second one for everyday use. `site-defaults.json` in the repository root is ignored by Git, so working settings never end up in a commit.

### Build a configured app

`./build-app.sh` folds a settings file into the bundle it builds, which is the third location above. That gives you an app that is already set up, ready to hand to your team. It uses `site-defaults.json` unless you name another file:

```bash
./build-app.sh                                    # your own settings, or none
SITE_DEFAULTS=teya-defaults.json ./build-app.sh   # a Teya build
```

A `swift run` development build has no bundle to fold a file into, so use one of the first two locations instead.

### What goes in it

| Field | What it does |
| --- | --- |
| `dispatch.oauth` | The identity provider both API environments sign in against. `grant` is `authorizationCodePKCE` or `clientCredentials`. `authURL`, `tokenURL`, `clientID`, `scope`, and `callbackURL` are the usual OAuth values. Anything you leave out keeps the app's own default. |
| `dispatch.requests` | The saved requests a first run starts with, each a `name`, a `method`, and a `url`. `{{env}}` in a URL becomes `dev` or `prd` depending on the environment the request is sent from. |
| `grafana.presets` | The instances offered in the Add server sheet. A preset is a `scope`, an `environment`, and a `url`. The agents know each one as `grafana-<scope>-<environment>`. `serves` lists which troubleshooting environments (`dev`, `prod`) offer it, and a preset that lists none is offered for all of them. |
| `skills` | The marketplace the Skills screen installs from: its `name` on screen, its `marketplace` name as the agent CLIs know it, and the `repository` it is cloned from. |

The client secret and the OAuth tokens are yours rather than your organisation's, so they are never part of this file. They stay in the macOS Keychain.

If the file cannot be read, the app starts with everything empty and writes the reason to its standard error, so a typo does not look the same as having no file at all.

## Get started

1. Open Teya Conductor and add a project folder.
2. Open Settings to choose the default agent and its access settings.
3. Start a session and choose whether it should use the project folder or an isolated worktree.
4. Describe the task, attach any useful files, and follow the work in Chat, Changes, Explorer, or Terminal.

For development setup, tests, architecture, and project conventions, see [CONTRIBUTING.md](CONTRIBUTING.md).
