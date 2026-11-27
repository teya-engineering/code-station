# ADR 0007 - Kiro agent

## Context

People who use AWS Kiro want to run it in Code Station the way they run the other agents: with their own account and plan, inside the app's transcript, permissions and changes view. Some tools reach Kiro's models by reusing its sign-in tokens against its backend, which relies on endpoints Kiro does not document and may break its terms.

Kiro's CLI speaks the Agent Client Protocol (ACP) over standard input and output. It can be signed into through GitHub, Google, AWS Builder ID or an organisation's sign-in, and it bills in plan credits rather than dollars. Several of the details the app relies on, such as where Kiro records a sign-in, are not documented.

## Decision

Code Station runs Kiro only through the official CLI, as a session server: `kiro-cli acp --agent-engine v3`. The engine is pinned so a person's own Kiro settings cannot move the app onto a protocol it does not speak.

Kiro ships as a **beta**. It is marked BETA wherever it can be picked, and its settings say what works. It leaves beta once the sign-in check has held for every kind of sign-in, or Kiro offers a supported way to ask. Leaving beta is one flag.

- **Sign-in.** Signing in runs plain `kiro-cli login`, whose own menu covers every way in, so the app keeps no sign-in fields. The app asks `kiro-cli whoami` and also reads the names of the keys in Kiro's local database, never their values. `whoami` reads organisation sign-ins as signed out, so an organisation token in the database wins over its answer. For any other sign-in, `whoami` saying signed out wins, since an expired token stays in the database until the next login.
- **Permissions.** Kiro asks before tool calls its own settings do not already allow. The session's access mode answers edits only when their paths resolve inside its own folders, including through relative paths and symlinks; everything else becomes the usual permission card. Kiro has no judge for risky steps, so "Risky only" is not offered, and it takes no effort level, so effort is hidden.
- **Replies.** Text and thinking reach the transcript as Kiro writes them. A prompt stays open for the whole turn, so it has no RPC deadline; opening and configuring a session still time out. A resumed session replays its history, which the app drops because it already holds it.
- **MCP servers.** The app's servers are handed to each session when it opens, following the session's choices. Nothing is written to Kiro's own configuration, which would load them in every Kiro session with no way to switch one off.
- **Credits.** Sessions show the plan credits each turn reports, written as Kiro writes them: two decimals with a point.
- **Kiro's home.** Kiro keeps its settings, profiles, skills and history in `~/.kiro`, or in `KIRO_HOME` when that is an absolute folder that does not hold the home folder. The app follows the same rule everywhere it touches that folder, so imports, profiles and skills all land where Kiro looks.
- **Importing past sessions.** Kiro's own server lists a folder's sessions, page by page, copies the chosen one, and replays the copy into the transcript. The original is never touched, and later turns continue the copy.
- **Skills.** Kiro has no command that installs marketplace packages, and the packages it can install are not loaded by its ACP engine. It does load every skill in the `skills` folder of its home, so installing a package for Kiro copies the package's skills there, each marked with the package it came from. Only marked copies are updated or removed.
- **One-shot runs.** Prompt suggestions and second opinions run as `kiro-cli chat --no-interactive` on the pinned V3 engine, each under a unique profile of its own. A second opinion's profile has only read tools; a suggestion's has none and denies reading too. The profile's explicit denials block writes, shell commands, MCP calls, powers and delegation even when saved rules allow them, which a flag that trusts no tool cannot do. The profile lives in Kiro's global agents folder for the run and is removed afterward; existing profiles and settings stay intact. If the profile cannot be created, the run does not start.

## Consequences

- Kiro sessions get the same transcript, permission card, queue, changes view and follow-ups as the other agents, on the person's own account and plan.
- The app depends on details Kiro may change: the ACP engine, its extensions and the layout of its database. A changed database falls back to `whoami`; a changed protocol fails sessions visibly.
- Kiro cannot take a prompt during a turn, so mid-turn prompts queue, as they do for Copilot.
- Servers in Kiro's own configuration always load, even in a session with MCP switched off.
- A marketplace package brings only its skills to Kiro. Its agents, commands, hooks and MCP servers are left behind, and only packages kept inside the marketplace's repository can be copied.
- Each import leaves its copy in the person's Kiro history.
- Protocol behaviour is covered by tests built from recorded ACP messages and a fake ACP server. An opt-in live test runs a real Kiro turn through the app with a throwaway MCP server.
