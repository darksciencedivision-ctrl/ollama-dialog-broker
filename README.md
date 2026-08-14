# Ollama Dialog Broker

A deterministic, non-agentic dialog orchestration system for running structured conversations between two local large language models using Ollama.

Designed for research, reproducibility, and long-duration observation.

## Core Properties

- Deterministic turn control
- File-driven operator inputs
- Non-agentic execution
- Bounded context with rolling continuity
- Append-only logs for auditability

## High-Level Architecture

```
Operator
 ├─ inbox/topic.txt
 ├─ inbox/interject.txt
 ↓
Broker (PowerShell)
 ├─ Turn controller
 ├─ Prompt constructors
 ├─ Ollama API adapter
 ├─ Failure guardrails
 ↓
Model A ↔ Model B
 ↓
logs/dialog.txt
logs/system.txt
```

See [docs/architecture.md](docs/architecture.md) and [docs/control-rules.md](docs/control-rules.md) for details.

## Running

Requirements:

- Windows 10 / 11
- PowerShell 5.1 or later
- [Ollama](https://ollama.com) running locally (default endpoint `http://127.0.0.1:11434`)
- The two models the broker defaults to, pulled via `ollama pull`:
  - `qwen2.5:14b-instruct` — Builder (Model A)
  - `dolphin-llama3:latest` — Challenger (Model B)

Start the broker:

```powershell
.\broker\broker.ps1
```

By default the broker uses the repository root as its working directory: it creates `inbox/` and `logs/` there, and stops when a file named `STOP` appears in the root. Models, pacing, output limits, and the working root are all overridable via parameters (see the `param` block in `broker/broker.ps1`).

Optional OBS-friendly live view of the running dialog:

```powershell
.\presentation\watch_obs.ps1
```

Operator controls while running:

- Write a topic to `inbox\topic.txt` to force a new topic (resets the conversation)
- Write a line to `inbox\interject.txt` to inject a one-shot steering note (no reset)
- Create a `STOP` file in the root to shut down cleanly

## Non-Goals

- No agents
- No tools
- No persistent memory
- No autonomous planning

## Licensing

This project is dual-licensed:

- **Non-commercial use** (educational, academic research, personal, non-monetized demonstrations) is free under the Non-Commercial License in [LICENSE](LICENSE)
- **Commercial use** requires a paid license — see [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)
