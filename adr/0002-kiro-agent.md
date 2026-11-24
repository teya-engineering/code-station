# ADR-0002: Kiro as a coding agent

## Status

Proposed

## Context

People who use AWS Kiro want to run it in Code Station the way they run Claude Code, Codex and Copilot: their own account, their plan's models, and the app's transcript, permissions and changes around it. Some model-agnostic tools reach Kiro's models by reusing its sign-in tokens against its backend. That relies on endpoints Kiro does not document and may break its terms.

Kiro's CLI, `kiro-cli`, speaks the Agent Client Protocol (ACP) with `kiro-cli acp`: JSON-RPC over stdin and stdout, one message per line. It has two engines. V2 frames server requests with string ids and names its extensions `_kiro.dev/*`. V3, the default since CLI 3.5, uses numeric ids, `_kiro/*` extensions, model choice through `session/set_config_option`, and replay markers on a loaded session.

Kiro can be signed into through GitHub, Google, AWS Builder ID, or an organisation (IAM Identity Center or an external identity provider such as Okta or Entra ID). Testing with an organisation account showed two things. First, `kiro-cli login --license pro --identity-provider <url> --region <region>` still opens Kiro's own sign-in page, which already offers the organisation's sign-in. Second, the app read that tester's `kiro-cli whoami` as signed out even though their sessions worked.

## Decision

Kiro ships as a beta. It works end to end, but it lacks parts the other agents have, and its sign-in check rests on details Kiro does not document. The app says so wherever Kiro can be picked, so nobody mistakes the gaps for faults:

- `AgentKind.isBeta` marks it. Agent menus describe it as "Beta · AWS's coding agent." The session bar shows a `BetaChip` beside its name, with the explanation in the tooltip. The first-run wizard shows the chip on its card.
- The Kiro section of Settings › Agents carries a BETA badge and one sentence on what beta means: what works, and what is not supported yet.

Kiro leaves beta once the sign-in check has been confirmed against each kind of sign-in, or once Kiro offers a supported way to ask. Leaving beta means setting `isBeta` to false.

Code Station runs Kiro through the official CLI as a session server, `kiro-cli acp --agent-engine v3`. The engine is pinned so that a user's own `acp.agentEngine` setting cannot switch the app onto a protocol it does not speak. The minimum CLI version is 3.5.0.

`AgentServerLaunch` builds the launch, and `AgentSessionConnection` handles the protocol:

- `initialize`, then `session/new` or `session/load`. Then `session/set_config_option` for the model, and for Kiro's `plan` mode when the session plans. Then `session/prompt`.
- The answer to the prompt ends the turn. `session/cancel` stops it.
- A loaded session replays its history marked `replay`. `KiroStream` drops those updates, because the transcript already holds them.
- `KiroStream` maps `session/update` notifications onto `StreamEvent`. Text and thinking reach the transcript chunk by chunk as Kiro writes them, through `textChunk` and `thinkingChunk` events that say whether they carry on the current block. A tool call or a turn boundary ends the block. Tool calls are renamed onto the names the app already draws (Read, Edit, Write, Bash).

Tool access goes through ACP's `session/request_permission`. The session's access mode answers file edits inside the session's folders when edits are allowed. Every other request becomes the existing permission card, and its answer selects the option Kiro offered for allow once, always allow, or deny. Kiro offers "Allow edits", "Every step" and "Plan only". It has no judge for risky steps, so "Risky only" is not offered. Kiro takes no effort level, so effort is hidden, or locked on Default where a form needs the field.

Code Station's MCP servers reach Kiro per session, not through Kiro's own configuration. `session/new` and `session/load` take an `mcpServers` list. Kiro loads those servers for that session only, alongside its own. The runner builds the list from the app's servers, following the session's choices: MCP off hands over none, a session narrowed to some servers gets only those, and servers switched off in the app or for the session are left out. Local commands are resolved to full paths. Remote servers keep their headers. Nothing is written to `~/.kiro`, so the servers do not appear in `kiro-cli` outside Code Station. Registering them there would load them in every Kiro session, and Kiro cannot switch a server off for one session. MCP calls are shown like other agents' (`MCP`, `server.tool`). Kiro's own "Tool Load" call, which loads an MCP tool before using it, is hidden.

Signing in runs plain `kiro-cli login`, in the same terminal sheet as the other agents. The app keeps no sign-in fields of its own, because Kiro's menu covers every way in.

The Agents pane decides whether someone is signed in from two sources. It reads the key names in the `auth_kv` table of `~/Library/Application Support/kiro-cli/data.sqlite3`, read-only and never the values: `kirocli:social:token` is a GitHub or Google sign-in, `kirocli:odic:token` an organisation's, and an empty table is a sign-out. It also asks `kiro-cli whoami --format json`, which names the account when it knows it. A token in the database counts as a sign-in whatever `whoami` said. When neither can be read, the pane shows what the CLI said instead of guessing.

The skills marketplace installs into Kiro by copying files, because `kiro-cli` has no plugin command that takes the marketplace's packages. `kiro-cli powers install` takes a folder with a root `plugin.json`, but the v3 engine does not load installed powers. It does load every `~/.kiro/skills/<name>/SKILL.md`, as a skill and a slash command. So installing a package copies the folders under its `skills/` there, from the app's own copy of the marketplace, each with a `.code-station-package.json` marker naming the package, its marketplace and its version. The marker is how the installed list is read back, and how an update or uninstall finds the copies without touching a skill the person added themselves. A skill of the same name that the app did not put there stops the install. Only packages kept inside the marketplace's repository can be copied. A package's agents, commands, hooks and MCP servers have no place in Kiro and are left behind.

Titles and prompt suggestions run as one-shot `kiro-cli chat --no-interactive` runs. Second-opinion reviews run the same way, trusting only `fs_read`, `grep` and `glob`. A non-interactive run refuses every untrusted tool, so a review cannot write or run commands.

## Consequences

Kiro is visibly a beta, so its gaps read as expected rather than broken, and the label sets the bar for leaving it. One flag removes the label everywhere.

Kiro sessions get the same transcript, permission card, queue, changes view and follow-ups as the other agents. They use the person's own Kiro account and plan.

The app depends on details Kiro may change: the V3 protocol, its extension names, and the layout of its database. A change to the database layout makes the sign-in check fall back to `whoami`, which has read organisation accounts as signed out. A change to the protocol fails sessions visibly rather than silently.

Kiro cannot take a prompt during a turn, so mid-turn prompts queue, as they do for Copilot. Past Kiro sessions are imported the way Codex's and Copilot's are, through Kiro's own server: `session/list` finds the folder's local sessions, `session/fork` copies the chosen one so the original is never touched, and `session/load` on the copy replays the conversation, marked as replay, into the transcript. Later turns resume the copy. Kiro keeps its history in `~/.kiro` with no setting to move it, so the import offers no history folder for Kiro. Kiro counts usage in plan credits, not dollars: each turn's summary reports what it cost, the adapter passes a running total, and sessions show credits where other agents show dollars.

Servers in Kiro's own configuration load in every Kiro session, and Kiro has no way to switch them off for one session. A session with MCP off is handed none of Code Station's servers, but Kiro's own still load. Kiro reviewers and prompt suggestions run as one-shot chats and get no MCP servers from the app.

Protocol behaviour is covered by tests built from recorded ACP messages, and by a fake ACP server in the runner tests. A live organisation sign-in was confirmed by a tester. The app's own tests cannot exercise one.
