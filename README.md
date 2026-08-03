# Claude Conductor

A small macOS app for running Claude Code against your projects, plus the MCP server
manager it grew out of. It is a stripped-down take on Conductor: same idea of a project
list and a chat per session, but only Claude Code, and no worktrees.

It lives in the Dock. Closing the window leaves it running; click the Dock icon to bring
it back.

## How it works

A project is just a folder on your Mac. Claude Code runs **in that folder itself**, so
its edits land straight in your working tree. Nothing is copied and no branch is created.

That is the main trade-off. Two agents in one folder would overwrite each other, so
parallel work comes from adding several projects rather than running several sessions in
one. To make the lack of an isolated worktree safe, every session has a **Changes** tab
showing the uncommitted diff, so you can see what the agent did before you keep it.

## What it does

### Projects and sessions

- **+ Add project** picks a folder. A folder can only be added once.
- Each project holds a list of sessions. A session is one conversation with Claude Code.
- The chat streams replies as they arrive, and shows each tool call with its input and
  result, so you can watch what the agent is doing rather than only the final answer.
- **Changes** shows the branch, the changed files with per-file `+`/`-` counts, and the
  diff for any file you select. It is strictly read-only: nothing here stages, commits,
  or discards anything.
- Sessions are resumed through Claude Code's own `--resume`, so context survives quitting
  the app. If Claude Code has forgotten a conversation, the next message starts a fresh
  one and says so instead of failing.
- Projects and sessions are stored in `~/.config/claude-conductor/projects.json`.

Claude Code is run as `claude -p --output-format stream-json`, so the CLI owns
permissions, model choice, and MCP wiring. Whatever `claude` does in a terminal in that
folder is what happens here.

### MCP Servers

The **MCP Servers** entry at the bottom of the sidebar is the original config manager,
unchanged. Server definitions live in `~/.config/mcp/config.json`; the "Add to Claude
Code" button is what actually makes a server usable, by registering it with Claude Code.

- Lists configured servers with live running state and an env count.
- Shows each server's command and environment variables, masking the service account
  token behind a Reveal button.
- **Registers a server with the Claude Code CLI** ("Add to Claude Code"). This runs
  `claude mcp add <name> -s user -e ... -- <abs path>/mcp-grafana`, so Claude Code spawns
  the stdio server itself. The card shows whether the server is currently registered
  (read from `~/.claude.json`). Restart the Claude Code session to pick up a change.
- Starts and stops a local `mcp-grafana` process per server, separate from Claude Code.
  With no transport args configured it runs in `streamable-http` mode on a local port and
  shows the endpoint (e.g. `http://localhost:8000/mcp`); output is shown live and start
  failures are surfaced inline. Use this for quick testing or non-Claude clients.
- "+ Add server" offers two choices:
  - **Add Grafana MCP server**: pick a scope and environment; the name, URL, and command
    are filled in automatically.
    - name: `grafana-<scope>-<env>` (e.g. `grafana-platform-dev`)
    - url: `https://grafana.<scope>-<env>.example.com`
    - command: `mcp-grafana`
    - Scopes: `platform`, `cde`, `edge`. Environments: `dev`, `prd`.
  - **Add MCP server**: paste any server as JSON - a full `{ "mcpServers": { ... } }`
    block or a bare `{ "name": { ... } }` map. Supports stdio servers
    (`command`/`args`/`env`) and remote servers (`url`/`type`/`headers`).

Every edit is saved to the config file straight away.

## Requirements

- macOS 14+
- The Claude Code CLI on your PATH. Without it the app still runs and manages MCP config,
  but sessions cannot start and the sidebar says so.

## Run

From Xcode:

```bash
open Package.swift   # pick the MenuBarApp scheme and Run
```

From the terminal:

```bash
swift run
```

## Build a double-clickable app

```bash
./build-app.sh          # produces "build/Claude Conductor.app"
```

`swift run` has no Dock icon or app menu, because those come from the bundle. Use the
bundle for anything beyond a quick check.

The icon is drawn by `make-icon.swift` into `Resources/AppIcon.icns`. Run
`swift make-icon.swift` after changing the art.

## Notes

- The service account token is stored inline in the MCP config file, because MCP clients
  read the token from that file. Keep the file private. Moving secrets to the macOS
  keychain is a possible follow-up.
- MCP running state is in-memory: nothing is running right after the app starts, and all
  child processes are stopped when the app quits.
- `mcp-grafana` is resolved against the usual install dirs (`~/go/bin`, Homebrew, etc.)
  because a Finder-launched app has a minimal PATH. Install it with:
  `go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest`.
