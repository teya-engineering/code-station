# ADR 0002 - Agent sessions

## Context

Code Station runs Claude Code, Codex, GitHub Copilot CLI and AWS Kiro CLI. Each agent keeps its own CLI, account and settings, and each speaks a different protocol. The app still has to show one transcript, take follow-up prompts in the same conversation, know when background work ends, and stop that work when the user asks. A person may also want to carry a piece of work from one agent to another without losing the worktree or starting a new session.

## Decision

Each agent runs through its own long-lived protocol, not one process per prompt:

- Claude Code uses its streaming CLI protocol.
- Codex uses its local app server (JSON-RPC).
- Copilot uses its headless server.
- Kiro uses its Agent Client Protocol server (see [the Kiro ADR](0009-kiro-agent.md)).

A session owns one conversation per agent it has used, and only one of them is live at a time. Each conversation is kept under its agent's own resume id. The live agent's process stays open while it has background work, and closes once the conversation is idle with no tasks left. Ending a wait asks the agent to cancel its tasks before the process is stopped and cleaned up.

The agent, model and effort only change between turns. While a turn runs they are locked, so a turn never runs on mixed settings. There is no queued change: a turn finishes, or is stopped, before anything changes. Access is not part of the lock.

Switching agents never touches the worktree, the branch or uncommitted changes. One agent cannot reuse another's memory, so the next agent is handed a written note by default, and the person can edit it before it goes. The outgoing agent writes the note from the transcript in a throwaway run, since it knows the work best. The person can pick another writer: the agent taking over, which reads the transcript as text and writes its own brief, or the app, which lists the first ask, the edits and the commands without any agent. This keeps a switch possible when the outgoing agent is the one that is down. When the chosen agent does not answer, the app's plain list stands in and the dialog says so. The person can instead hand over the whole transcript as text, or nothing but the worktree. The note goes over as the new agent's first turn, which is sent by the app and stays out of the transcript. A marker in the transcript records every switch and every model or effort change. An agent coming back resumes its own conversation and is only told what happened after it left. A switch that fails before the last step leaves the session as it was. Access never gets looser on a switch unless the person picks it.

Adapters turn each protocol into one shared stream of events, so the transcript, waiting notice and session state work the same for every agent. Unknown events are ignored, and unknown server requests get an explicit error.

`SessionRunner` owns the connection, the prompt queue and cancellation. A prompt sent during a turn joins that turn when the agent supports it (Claude Code and Codex). Otherwise it waits for the turn to end (Copilot and Kiro). Titles, recaps and suggestions run as normal turns through the same queue.

Settings such as model, access level, workspace roots and MCP servers are resolved before each launch and passed as arguments or server parameters. Prompt text is only ever data, so it can never change what the agent is allowed to do. The connection never approves a request outside the session's chosen access level.

## Consequences

- The waiting notice, follow-ups and ending a turn behave the same across all four agents.
- A session can list more than one agent, and its transcript holds turns from each, split by markers.
- Winding a conversation back stops at the last agent switch, since the agent before it never saw the turns after it.
- Agents are never run at the same time on one worktree, conversations are never converted from one agent's format to another's, and settings such as MCP servers and skills are not copied between agents.
- The installed Codex, Copilot and Kiro versions must support their server and task APIs. When they do not, the session fails visibly instead of guessing, and a switch to an outdated CLI stops before anything changes.
- Normal tests use recorded protocol messages and make no model calls. Live tests need signed-in accounts and are opt-in.
