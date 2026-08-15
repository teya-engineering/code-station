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
- Rewind a Claude Code conversation to an earlier prompt and send it again, or fork it into a new session from that point, from the prompt's right-click menu.
- Get a system notification when a session finishes a turn or stops to ask something while the app is in the background. Clicking it opens that session.
- Review what a session changed and commit it without leaving the app: pick exactly the files that go into a commit, amend the last commit while it is still unpushed, and read recent commits with their full diffs.
- Read code as code: chat code blocks, file previews, and diffs are syntax highlighted, with no extra dependencies.
- See images where they belong: files sent with a prompt and local images the agent references render inline in the conversation, and click open at full size.
- Know what a conversation costs: each session shows its spend alongside the context meter, and each agent's settings can hide the figure.
- Read at a size that suits you: Cmd+ and Cmd- resize the transcript, tool output, diffs and the terminal, and Cmd0 puts them back. The same choice sits in Settings, and the app's own headers and controls keep their size so nothing crops.

### Built-in tools

- Configure MCP servers and register them with Codex, Claude Code, or both.
- Install and update agent skills from your organisation's marketplace.
- Save and send HTTP requests with environment variables, path and query parameters, headers, request bodies, and OAuth secrets and tokens stored in the macOS Keychain.
- Inspect running Docker containers and stop them when needed.
- Save, edit, run, and stop shell-command shortcuts while inspecting their output. Where a shortcut runs follows from where you saved it, so there is nothing to choose. The Shortcuts screen holds this Mac's own, which run from your home folder and are the ones your site settings can seed. A project's own are saved from a session and sit in that session's status row, alongside its state and branch, where they run in the session's worktree and each chip carries one glyph for how the last run went. The project screen keeps the same commands behind a count on its own status row, where a run happens in the project folder. Output opens in a drawer as soon as a run starts.
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
git clone https://github.com/<org>/teya-conductor.git
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

A few features point at things that belong to your organisation rather than to the app: the identity provider your APIs sign in against, the calls worth starting from, what your environments are named, your Grafana instances, the skills marketplace your agents install from, and the commands worth having on hand. None of that is in the code. It is all data, in a settings file the app reads at startup.

Every section is optional, and so is the file itself. Without it the app runs with blank API environments, no saved requests, no Grafana presets, no shortcuts, and the Skills screen reporting that no marketplace is set up. Everything else works as normal.

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
| `dispatch.environments` | What `{{env}}` stands for on each side of the sheet: a `staging` and a `production` word. Left out, they are `dev` and `prd`. |
| `dispatch.requests` | The saved requests a first run starts with, each a `name`, a `method`, and a `url`. `{{env}}` in a URL is replaced with the word above for the environment the request is sent from. |
| `grafana.presets` | The instances offered in the Add server sheet. A preset is a `scope`, an `environment`, and a `url`. The agents know each one as `grafana-<scope>-<environment>`. `serves` lists which troubleshooting environments (`dev`, `prod`) offer it, and a preset that lists none is offered for all of them. |
| `skills` | The marketplace the Skills screen installs from: its `name` on screen, its `marketplace` name as the agent CLIs know it, and the `repository` it is cloned from. |
| `shortcuts` | The command shortcuts a first run starts with, each a `name` and a `command`. They run from your home folder, since the file cannot know which projects you have added. Everyone can then add their own, including ones filed under a project, which are saved per install and never overwritten by this file. |

The client secret and the OAuth tokens are yours rather than your organisation's, so they are never part of this file. They stay in the macOS Keychain.

If the file cannot be read, the app starts with everything empty and writes the reason to its standard error, so a typo does not look the same as having no file at all.

## Get started

1. Open Teya Conductor and add a project folder.
2. Open Settings to choose the default agent and its access settings.
3. Start a session and choose whether it should use the project folder or an isolated worktree.
4. Describe the task, attach any useful files, and follow the work in Chat, Changes, Explorer, or Terminal.

For development setup, tests, architecture, and project conventions, see [CONTRIBUTING.md](CONTRIBUTING.md).
