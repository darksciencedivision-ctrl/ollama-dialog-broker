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

## Non-Goals
- No agents
- No tools
- No persistent memory
- No autonomous planning

MIT License.
