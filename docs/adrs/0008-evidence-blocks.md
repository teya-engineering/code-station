# ADR 0008 - Evidence blocks

## Context

An agent that diagnoses a problem reads metrics, traces and logs, and then has to show what it found. Prose about a chart is weak evidence, and a picture the agent draws elsewhere cannot be checked or kept. The app could fetch the data itself, but it would then need its own way into every monitoring system an organisation runs, and a chart that refetches can quietly stop agreeing with the words around it.

## Decision

**The agent writes the evidence into its reply, and the app only draws it.** A reply can hold three kinds of fenced block, each carrying JSON: `chart`, `trace` and `logs`. The app has no client for Grafana or any other source. The agent fetches with its own tools, so the app works with whatever the agent can reach.

**A block carries all of its data.** Nothing in a block is a link or a query to run again. The reply is the record: a week later the source may have let the data go, and the block still shows what the finding rested on. Zooming, measuring and reading values all work on the points already in the block.

**Asking for more goes back through the agent.** A result that wants a wider window, the logs of a span or a closer look at a stretch of a chart sends the agent a follow-up, the same as typing it would. The answer arrives in the conversation as new evidence.

**The contract only grows by optional fields.** A block written before a field existed must still draw, and an unknown or malformed field is dropped without failing the block. A block that cannot be read at all says so and offers to ask for it again, and never disappears. One that is whole but empty is an answer, not a failure.

**The block says what the data means, and the app decides how it looks.** A chart block names units, levels and which side of a level is the breach, moments, stretches of time and windows worth jumping to. It never names a colour, a size or an axis. From that the app draws one scale per unit, never two scales on one plot, since two invite reading crossings that mean nothing. A projection is marked as one and never drawn as a solid line. Red is kept for a breach or a failure.

**Blocks are capped.** Each kind has a limit on series, points, spans or lines, so a reply never costs more than the answer it supports. The agent is told to sample or pick, and to say how much it left out.

**The agent learns the contract from the app.** The shape of each block is told to the agent as text, with an example, and that text lives beside the parser that reads the block. Every session is told about charts. A diagnosis is also told about traces and logs. `TranscriptChartSpec` and `TranscriptEvidenceBlocks` are the places to look.

**Volume is only shown when the app holds the whole result.** The strip of log volume above a list of lines is counted from a full query result the agent's tool returned. Lines the agent picked for a `logs` block get no strip, since the lines left out are the ones that would say how busy the log was.

## Consequences

- The app needs no credentials, network access or client code for any monitoring system, and a new source needs no app change as long as the agent can read it.
- Evidence stays readable after the source has expired, and never drifts from the reply it sits in.
- The app cannot refresh or widen a chart on its own. Every such step is a turn with the agent, which costs time and tokens.
- The agent can write a block wrong or copy a value wrong. The app can check the shape of a block but not its truth.
- A change to a block must update the parser, the text the agent is told and the tests that read the examples back, all together.
- A field can be added freely. Renaming or removing one breaks every reply already stored, so it is not done.
