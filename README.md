# Teya Conductor

A small macOS app for running Claude Code or Codex against your projects, plus the MCP
server manager it grew out of. It is a stripped-down take on Conductor: a project list
and a chat per session.

It lives in the Dock. Closing the window quits the app, so anything still running stops
with it.

## How it works

A project is just a folder on your Mac. A session runs Claude Code either **in that
folder itself** - edits land straight in your working tree - or in a **git worktree**:
an isolated checkout on its own branch, kept under
`~/Library/Application Support/com.teya.conductor/worktrees`.

Starting a new session in a git repository asks which of the two you want. Sessions
that share a folder cannot run at the same time, because two agents would edit the same
files underneath each other; worktree sessions each have their own folder, so they run
in parallel freely. In a folder that is not a git repository the session just runs in
place, since there is nothing to make a worktree from.

Either way, every session has a **Changes** tab showing the uncommitted diff of its
folder, so you can see what the agent did before you keep it.

## What it does

### Projects and sessions

- **+ Add project** picks a folder. A folder can only be added once.
- Each project holds a list of sessions. A session is one conversation with Claude Code.
- New sessions in a git repository choose between the project folder and a worktree.
  A worktree session shows its branch in the header, and its Changes tab diffs the
  worktree, not the project folder.
- Deleting a worktree session removes its worktree. Uncommitted changes there are lost;
  the branch is deleted only when git considers that safe, so committed work survives
  as a branch in the main repository.
- The chat streams replies as they arrive. Tool calls collapse into one activity spine:
  one line per call, with what it touched and a short note (`413 lines`, `+4 -1`,
  `running`). Clicking a row expands it in place - an edit shows the diff it made, and
  anything else shows its input and output.
- The header shows the working tree totals (`+38 -6 in 3 files`) live while the agent
  works; clicking them opens **Changes**.
- The composer takes files as well as text: paste a screenshot or a copied file with
  `⌘V`, or drop files onto it. They ride along with the next message as paths, and
  anything outside the session's folder is opened up to the agent with `--add-dir`.
  Pasted images are written to
  `~/Library/Application Support/com.teya.conductor/attachments` and cleared out after
  a week.
- The agent can ask back. A tool that needs permission and a question the agent wants
  answered both land as a card at the foot of the chat, and the turn waits there until
  you answer it. Permission cards offer **Allow**, **Deny**, and whatever the CLI thinks
  "don't ask again" should mean here; question cards show the options, take several
  answers at once when the question allows it, and always let you type something else.
  Settings chooses how much gets asked about.
- Codex sessions are sandboxed by default. Choose **Approve for me** to keep the
  sandbox while Codex automatically reviews permission requests. Choose **Full access**
  when the agent needs a local service outside the sandbox, such as your GPG agent for a
  signed commit. Full access can reach any file and the internet, so use it only with
  code you trust.
- **Changes** shows the branch, the changed files with per-file `+`/`-` counts, and the
  diff for any file you select. It is strictly read-only: nothing here stages, commits,
  or discards anything.
- **`>_ Terminal`** in the header opens a real shell in the session's folder, so you
  can build, test, and commit without leaving the app or losing sight of the
  conversation. It opens under the composer and takes nothing from the chat while it is
  shut. `^\`` opens it and moves between the composer and the shell, dragging the tab
  strip resizes it, and **Close** puts it away with every shell left running. Each tab
  is its own shell; `+` opens another, double-click a tab to rename it, and a green dot
  means a command is running in that tab right now.
- A running session shows its current tool in the sidebar; an idle one shows how many
  lines its edits added.
- `CONDUCTOR_STORE=/path/to/projects.json` points the app at a different store file,
  which is handy for trying the UI against staged data.
- Sessions are resumed through Claude Code's own `--resume`, so context survives quitting
  the app. If Claude Code has forgotten a conversation, the next message starts a fresh
  one and says so instead of failing.
- Projects and sessions are stored in `~/Library/Application Support/com.teya.conductor/projects.json`.
  What was open last time is a preference, so it lives in UserDefaults rather than that
  file. The Postman panel keeps its requests in the same folder, and its OAuth client
  secret and token in the Keychain. Anything an older version left in
  `~/.config/claude-conductor` is moved across on first launch.

Claude Code is run as `claude -p` with JSON streaming both ways
(`--output-format stream-json --input-format stream-json --permission-prompt-tool stdio`),
so the CLI owns permissions, model choice, and MCP wiring. Whatever `claude` does in a
terminal in that folder is what happens here. Streaming input is what lets it ask
anything back: prompts arrive as control requests on its stdout and the answer goes down
its stdin, and a session that cannot answer gets its tool calls denied instead.

The drawer's terminal is a full terminal emulator, built on
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and drawn in the app's own
palette. Shells, builds, and full screen programs (`vim`, `htop`) all work the way they
do in Terminal.app.

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

## Tests

```bash
swift test
```

Covers the terminal: the ANSI parser, and a real shell on a real pty answering what is
typed at it.

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
./build-app.sh          # produces "build/Teya Conductor.app"
```

`swift run` has no Dock icon or app menu, because those come from the bundle. Use the
bundle for anything beyond a quick check.

The app mark lives at `Sources/MenuBarApp/Resources/AppIcon.png`, and is shown both in
the sidebar and, through `make-icon.swift`, as the Dock icon. Replace that file and run
`swift make-icon.swift` to rebuild `Resources/AppIcon.icns`.

## Notes

- The service account token is stored inline in the MCP config file, because MCP clients
  read the token from that file. Keep the file private. Moving secrets to the macOS
  keychain is a possible follow-up.
- MCP running state is in-memory: nothing is running right after the app starts, and all
  child processes are stopped when the app quits.
- `mcp-grafana` is resolved against the usual install dirs (`~/go/bin`, Homebrew, etc.)
  because a Finder-launched app has a minimal PATH. Install it with:
  `go install github.com/grafana/mcp-grafana/cmd/mcp-grafana@latest`.
