# Architecture Overview

A single authoritative broker process (`broker/broker.ps1`) enforces strict alternation between two locally hosted models. Models never communicate directly: every prompt is constructed, routed, and validated by the broker, which is the only component that talks to the Ollama HTTP API.

## Process Model

The broker is one synchronous PowerShell loop. Each iteration:

1. Checks for a `STOP` file (clean shutdown) and operator inputs in `inbox/`
2. Builds the next prompt for whichever model is due (A = Builder, B = Challenger)
3. Calls Ollama's `/api/generate` endpoint (non-streaming, with a request timeout and a 9,000-character defensive prompt cap)
4. Validates and truncates the reply, then appends it to the logs
5. Sleeps for the configured pacing delay before the next turn

There is no concurrency and no background state: everything the broker knows is either in local variables for the current topic or in the append-only logs.

## File Layout (Working Root)

The working root defaults to the repository root and is parameterized via `-Root`:

```
<root>/
├─ inbox/
│  ├─ topic.txt        # operator topic override (resets conversation)
│  └─ interject.txt    # one-shot steering input (consumed and deleted)
├─ logs/
│  ├─ dialog.txt       # conversation lines with turn number and latency
│  └─ system.txt       # system events, errors, topic rotations
└─ STOP                # create this file to end the broker
```

## Context and Continuity

Model context is deliberately bounded. A prompt contains at most: the current topic, a rolling **anchor summary** (a compact 5–8 line continuity digest regenerated every `SummaryEveryTurns` turns by Model A), the other model's last turn, and any pending operator interjection. Older turns are never replayed — long-run coherence comes entirely from the anchor, which keeps prompt size flat over multi-hour sessions.

## Autopilot Topic Selection

In autopilot mode, topics are generated in a two-step handshake: Model A proposes exactly three candidate topics within a constrained content policy, Model B picks one. Topics rotate automatically every `TopicRotateEveryTurns` turns; if generation fails, the broker falls back to a fixed list of safe seed topics. A manual `inbox/topic.txt` write always overrides autopilot.

## State

All durable state is append-only text in `logs/`. The dialog log records the speaker, turn number, per-call latency, and the (truncated) text of each turn, so a session can be audited or replayed after the fact. Everything else — topic, anchor, last turns — is ephemeral and reset on topic change.
