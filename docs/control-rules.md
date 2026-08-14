# Control Rules

The broker's behavior is governed by a small set of explicit, deterministic rules. All thresholds below are the defaults from the `param` block of `broker/broker.ps1` and can be overridden at launch.

## Turn Order

- Strict A → B → A → B alternation; exactly one model is generating at any time
- Model A (Builder) always opens a topic; Model B (Challenger) must include exactly one critique and one test/constraint per turn
- Each turn is required by the prompt contract to start with `Turn <n>.` followed by 6–10 single-sentence content lines

## Topic Reset

- Triggered by a change to `inbox/topic.txt` (detected by content comparison, so rewriting the same topic does not retrigger)
- Also triggered by autopilot rotation every 30 turns (`TopicRotateEveryTurns`)
- A reset clears the anchor summary, both models' last turns, and the turn counter, and logs the new topic to both logs

## Interjection

- One-shot operator input via `inbox/interject.txt`
- The file is read and deleted atomically at the start of the next turn; the receiving model is instructed to answer it first in two lines
- No conversation reset — topic, anchor, and turn counter are preserved

## Output Guardrails

- Replies are normalized and truncated to at most 1,700 characters / 12 lines (`MaxTurnChars` / `MaxTurnLines`)
- A reply is rejected as "too short" if it has fewer than 6 non-empty lines, is under 120 characters, or is only the `Turn <n>.` label
- A rejected reply gets exactly **one** retry with an explicit re-emission instruction; the retry's output is accepted as-is

## Failure Handling

- HTTP errors from Ollama are logged to `logs/system.txt` with the model name and message
- After any error the broker sleeps briefly (`ErrorSleepMs`) and continues with the next loop iteration — no infinite retry loops, no exponential state
- Autopilot topic generation failures fall back to a fixed list of safe seed topics

## Shutdown

- Creating a `STOP` file in the working root ends the loop cleanly at the next iteration boundary; the exit is logged
