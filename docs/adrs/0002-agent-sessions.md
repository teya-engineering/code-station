# ADR 0002 - Agent sessions

## Context

Code Station runs Claude Code, Codex, GitHub Copilot CLI and AWS Kiro CLI. Each agent keeps its own CLI, account and settings, and each speaks a different protocol. The app still has to show one transcript, take follow-up prompts in the same conversation, know when background work ends, and stop that work when the user asks.

## Decision

Each agent runs through its own long-lived protocol, not one process per prompt:

- Claude Code uses its streaming CLI protocol.
- Codex uses its local app server (JSON-RPC).
- Copilot uses its headless server.
- Kiro uses its Agent Client Protocol server (see [the Kiro ADR](0009-kiro-agent.md)).

Each session owns one process group and one conversation. The process stays open while the agent has background work, and closes once the conversation is idle with no tasks left. Ending a wait asks the agent to cancel its tasks before the process is stopped and cleaned up.

Adapters turn each protocol into one shared stream of events, so the transcript, waiting notice and session state work the same for every agent. Unknown events are ignored, and unknown server requests get an explicit error.

`SessionRunner` owns the connection, the prompt queue and cancellation. A prompt sent during a turn joins that turn when the agent supports it (Claude Code and Codex). Otherwise it waits for the turn to end (Copilot and Kiro). Titles, recaps and suggestions run as normal turns through the same queue.

Settings such as model, access level, workspace roots and MCP servers are resolved once, before launch, and passed as arguments or server parameters. Prompt text is only ever data, so it can never change what the agent is allowed to do. The connection never approves a request outside the session's chosen access level.

## Consequences

- The waiting notice, follow-ups and ending a turn behave the same across all four agents.
- The installed Codex, Copilot and Kiro versions must support their server and task APIs. When they do not, the session fails visibly instead of guessing.
- Normal tests use recorded protocol messages and make no model calls. Live tests need signed-in accounts and are opt-in.
