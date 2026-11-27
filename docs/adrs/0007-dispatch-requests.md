# ADR 0007 - Dispatch requests

## Context

Dispatch sends saved HTTP requests to the environments an organisation runs. One request list serves every environment, so the same request can go to a test system or a live one. Two things go wrong easily: a request goes to the wrong place, or the address on screen is not the address that is sent.

## Decision

**The address is the source of truth.** A request is written as a template: `{{property}}` is filled in from the environment, and `:name` in the path is filled in from a path parameter. Path parameters follow the address. Each `:name` gets one row, and a row cannot be added, turned off or removed by hand. A value whose name is no longer in the address is kept in the file but not used, so typing the name again brings the value back.

**What is shown is what is sent.** The "Goes to" line under the address is built from the same resolution the runner sends with. The view only adds the tint that marks which parts were filled in. If the two ever disagree, the runner's address is shown whole and untinted.

**The environment is read at the moment of sending.** It is picked in the header and named on the Send button. A live environment turns the button red and asks before every send. There is no way to turn the question off.

**One reason at a time.** A request that cannot be sent says the first thing to fix under the address, and the Send button carries the same sentence as its hint.

**The answer stays out of the way until there is one.** The response is one line until the first send. Answers are kept in memory per request and environment, and are gone when the app restarts.

## Consequences

- A path parameter cannot drift from the address, and there is no toggle to forget.
- A request file from an older version still loads. A path value that was switched off there reads as not set until it is typed again.
- A new kind of placeholder must be added to the resolver first, so that the editor, the preview and the send all agree.
- The marks beside each saved request, which show its last answer, are empty after a restart.
