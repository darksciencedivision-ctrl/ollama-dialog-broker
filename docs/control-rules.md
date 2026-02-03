# Control Rules

Turn Order:
- Strict A → B → A → B alternation

Topic Reset:
- Triggered by inbox/topic.txt change
- Clears anchor, last turns, and turn counter

Interjection:
- One-shot input via inbox/interject.txt
- No reset

Failure Handling:
- HTTP errors logged
- One retry for trivial outputs
- No infinite retry loops
