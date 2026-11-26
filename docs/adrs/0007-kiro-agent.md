# ADR 0007 - Kiro agent

## Context

People who use AWS Kiro want to run it in Code Station the way they run the other agents: with their own account and plan, inside the app's transcript, permissions and changes view. Some tools reach Kiro's models by reusing its sign-in tokens against its backend, which relies on endpoints Kiro does not document and may break its terms.

Kiro's CLI speaks the Agent Client Protocol (ACP) over standard input and output. It can be signed into through GitHub, Google, AWS Builder ID or an organisation's sign-in, and it bills in plan credits rather than dollars. Several of the details the app relies on, such as where Kiro records a sign-in, are not documented.

## Decision

Code Station runs Kiro only through the official CLI, as a session server: `kiro-cli acp --agent-engine v3`. The engine is pinned so a person's own Kiro settings cannot move the app onto a protocol it does not speak.

Kiro ships as a **beta**. It is marked BETA wherever it can be picked, and its settings say what works. It leaves beta once the sign-in check has held for every kind of sign-in, or Kiro offers a supported way to ask. Leaving beta is one flag.

- **Sign-in.** Signing in runs plain `kiro-cli login`, whose own menu covers every way in, so the app keeps no sign-in fields. The app decides whether someone is signed in from the names of the keys in Kiro's local database, never their values, and falls back to `kiro-cli whoami`, which reads some organisation sign-ins as signed out.
- **Permissions.** Kiro asks before tool calls its own settings do not already allow. The session's access mode answers edits only when their paths resolve inside its own folders, including through relative paths and symlinks; everything else becomes the usual permission card. Kiro has no judge for risky steps, so "Risky only" is not offered, and it takes no effort level, so effort is hidden.
- **Replies.** Text and thinking reach the transcript as Kiro writes them. A prompt stays open for the whole turn, so it has no RPC deadline; opening and configuring a session still time out. A resumed session replays its history, which the app drops because it already holds it.
- **MCP servers.** The app's servers are handed to each session when it opens, following the session's choices. Nothing is written to Kiro's own configuration, which would load them in every Kiro session with no way to switch one off.
- **Credits.** Sessions show the plan credits each turn reports, written as Kiro writes them: two decimals with a point.
- **Importing past sessions.** Kiro's own server lists a folder's sessions, copies the chosen one, and replays the copy into the transcript. The original is never touched, and later turns continue the copy.
- **Skills.** Kiro has no command that installs marketplace packages, and the packages it can install are not loaded by its ACP engine. It does load every skill in `~/.kiro/skills`, so installing a package for Kiro copies the package's skills there, each marked with the package it came from. Only marked copies are updated or removed.
- **One-shot runs.** Titles, prompt suggestions and second opinions run as `kiro-cli chat --no-interactive`. Second opinions pin the V3 engine and use a unique review profile with only read tools. Its explicit denials block writes, shell commands, MCP calls, powers and delegation even when saved rules allow them. The profile lives in Kiro's global agents folder for the run and is removed afterward; existing profiles and settings stay intact. If the profile cannot be created or loaded, the review fails.

## Consequences

- Kiro sessions get the same transcript, permission card, queue, changes view and follow-ups as the other agents, on the person's own account and plan.
- The app depends on details Kiro may change: the ACP engine, its extensions and the layout of its database. A changed database falls back to `whoami`; a changed protocol fails sessions visibly.
- Kiro cannot take a prompt during a turn, so mid-turn prompts queue, as they do for Copilot.
- Servers in Kiro's own configuration always load, even in a session with MCP switched off.
- A marketplace package brings only its skills to Kiro. Its agents, commands, hooks and MCP servers are left behind, and only packages kept inside the marketplace's repository can be copied.
- Each import leaves its copy in the person's Kiro history.
- Protocol behaviour is covered by tests built from recorded ACP messages and a fake ACP server. An opt-in live test runs a real Kiro turn through the app with a throwaway MCP server.
