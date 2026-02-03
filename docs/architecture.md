# Architecture Overview

A single authoritative broker process enforces strict alternation between two models.

Models never communicate directly.
All prompts are constructed, routed, and validated by the broker.

State is ephemeral except for append-only logs.
