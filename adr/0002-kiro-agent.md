# ADR-0002: Kiro as a coding agent

## Status

Proposed

## Context

People who use AWS Kiro want to run it in Code Station the way they run Claude Code, Codex and Copilot: their own account, their plan's models, and the app's transcript, permissions and changes around it. Some model-agnostic tools reach Kiro's models by reusing its sign-in tokens against its backend. That relies on endpoints Kiro does not document and may break its terms.

Kiro's CLI, `kiro-cli`, speaks the Agent Client Protocol (ACP) with `kiro-cli acp`: JSON-RPC over stdin and stdout, one message per line. It has two engines. V2 frames server requests with string ids and names its extensions `_kiro.dev/*`. V3, the default since CLI 3.5, uses numeric ids, `_kiro/*` extensions, model choice through `session/set_config_option`, and replay markers on a loaded session.

Kiro can be signed into through GitHub, Google, AWS Builder ID, or an organisation (IAM Identity Center or an external identity provider such as Okta or Entra ID). Testing with an organisation account showed two things. First, `kiro-cli login --license pro --identity-provider <url> --region <region>` still opens Kiro's own sign-in page, which already offers the organisation's sign-in. Second, the app read that tester's `kiro-cli whoami` as signed out even though their sessions worked.

## Decision

Code Station runs Kiro through the official CLI as a session server, `kiro-cli acp --agent-engine v3`. The engine is pinned so that a user's own `acp.agentEngine` setting cannot switch the app onto a protocol it does not speak. The minimum CLI version is 3.5.0.

`AgentServerLaunch` builds the launch, and `AgentSessionConnection` handles the protocol:

- `initialize`, then `session/new` or `session/load`. Then `session/set_config_option` for the model, and for Kiro's `plan` mode when the session plans. Then `session/prompt`.
- The answer to the prompt ends the turn. `session/cancel` stops it.
- A loaded session replays its history marked `replay`. `KiroStream` drops those updates, because the transcript already holds them.
- `KiroStream` maps `session/update` notifications onto `StreamEvent`. Text and thinking chunks are held and handed on as blocks. Tool calls are renamed onto the names the app already draws (Read, Edit, Write, Bash).

Tool access goes through ACP's `session/request_permission`. The session's access mode answers file edits inside the session's folders when edits are allowed. Every other request becomes the existing permission card, and its answer selects the option Kiro offered for allow once, always allow, or deny. Kiro offers "Allow edits", "Every step" and "Plan only". It has no judge for risky steps, so "Risky only" is not offered. Kiro takes no effort level, so effort is hidden, or locked on Default where a form needs the field.

Signing in runs plain `kiro-cli login`, in the same terminal sheet as the other agents. The app keeps no sign-in fields of its own, because Kiro's menu covers every way in.

The Agents pane decides whether someone is signed in from two sources. It reads the key names in the `auth_kv` table of `~/Library/Application Support/kiro-cli/data.sqlite3`, read-only and never the values: `kirocli:social:token` is a GitHub or Google sign-in, `kirocli:odic:token` an organisation's, and an empty table is a sign-out. It also asks `kiro-cli whoami --format json`, which names the account when it knows it. A token in the database counts as a sign-in whatever `whoami` said. When neither can be read, the pane shows what the CLI said instead of guessing.

Titles and prompt suggestions run as one-shot `kiro-cli chat --no-interactive` runs. Second-opinion reviews run the same way, trusting only `fs_read`, `grep` and `glob`. A non-interactive run refuses every untrusted tool, so a review cannot write or run commands.

## Consequences

Kiro sessions get the same transcript, permission card, queue, changes view and follow-ups as the other agents. They use the person's own Kiro account and plan.

The app depends on details Kiro may change: the V3 protocol, its extension names, and the layout of its database. A change to the database layout makes the sign-in check fall back to `whoami`, which has read organisation accounts as signed out. A change to the protocol fails sessions visibly rather than silently.

Kiro cannot take a prompt during a turn, so mid-turn prompts queue, as they do for Copilot. Text arrives a block at a time rather than word by word. The app does not yet hand its MCP servers to Kiro, import past Kiro sessions, or show credit usage; Kiro uses its own MCP configuration meanwhile.

Protocol behaviour is covered by tests built from recorded ACP messages, and by a fake ACP server in the runner tests. A live organisation sign-in was confirmed by a tester. The app's own tests cannot exercise one.
