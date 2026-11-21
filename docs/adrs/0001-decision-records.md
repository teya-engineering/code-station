# ADR 0001 - Decision records

## Context

Code Station needs one place that explains how the app is built and why. A new person, or a coding agent, should be able to read it and understand the main choices before they change the code.

## Decision

All docs live in `docs/`. Decisions live in `docs/adrs/`, one file per topic, named `NNNN-short-title.md`. Guides that explain how to use or extend something, such as the design system or site configuration, sit next to them in `docs/`.

An ADR is short and high level. It has three parts:

- **Context** - the problem and the forces at play.
- **Decision** - what is true now, and why.
- **Consequences** - what follows from it, good and bad.

Leave out class lists, method names and step-by-step flows. The code shows those, and they go stale fast. Name a type only when it is the main place a reader should look.

An ADR describes the current state, not a history. When a decision changes, rewrite the ADR so it says what is true now, and delete the old text. There is no status, date, "superseded by" or changelog. When a decision no longer applies at all, delete the ADR. Numbers are never reused.

## Consequences

- The docs can be trusted to match the code, because an out-of-date ADR is a bug to fix, not a record to keep.
- A change that alters a decision must update its ADR in the same change.
- Past reasoning lives only in Git history.
