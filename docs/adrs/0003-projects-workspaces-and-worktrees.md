# ADR 0003 - Projects, workspaces and worktrees

## Context

People run several agents at once, often on the same repository, and sometimes on a change that spans more than one repository. Two agents editing the same checkout would trip over each other.

## Decision

A project is a reference to a folder on disk. A workspace is a reusable group of projects with one lead project, whose folder is the agent's working directory. The other projects are attached to the same conversation.

A session can work in the project folder directly, or in a Git worktree with its own branch. In a workspace, each Git project can get its own worktree. The app manages these worktrees under `~/.code-station/`, which keeps paths short and free of spaces.

When a session starts, it records its own project paths and worktree choices. Editing a workspace later does not change a conversation that already exists.

## Consequences

- Sessions can run side by side on the same repository without sharing a checkout.
- Worktrees take disk space, so the app removes a session's worktree with the session and cleans up any it finds left behind.
- A session's setup is fixed at start, so to change which projects it covers, start a new session.
