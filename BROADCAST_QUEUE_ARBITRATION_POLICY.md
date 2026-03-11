# Broadcast Queue Arbitration Policy

This document defines how the scorebug decides which queued match should be on air when Volleyball Life data is incomplete, wrong, late, or contradictory.

## Primary goal

Prefer being slightly late over being wrong.

For broadcast, a stable and believable scorebug is better than instantly reacting to a bad human input event.

## Decision order

1. Keep the current active match if it is clearly live.
2. Keep the queue head when nothing else is strongly proven live.
3. Consider switching to another queued match only when there is stronger evidence than the current match.
4. Prefer the earliest confident queued match when multiple queued matches appear active.
5. Revert a later smart-switch only when that later selection was made automatically and the evidence disappears.

## Evidence levels

### Strong evidence

The app may switch immediately when a queued match shows any of:

- explicit live/in-progress/playing status
- multi-set evidence
- completed-set history
- four or more total points

### Weak evidence

The app does not switch immediately when a queued match only shows fragile early evidence, such as:

- a single accidental point
- a `1-0` or `2-0` score with no explicit live status
- inconsistent first-poll activity that could be operator error

Weak evidence must persist across the confirmation window before the app switches.

## Human-error scenarios covered

- accidental one-point activation on a later queued match
- later queued match started by mistake and then reset
- multiple queued matches looking active at once
- no-live-scoring matches where team names still need to stay on air
- manual queue edits that should not be overridden by recovery logic

## Regression guardrails

- happy-path later-live switching must still work
- manual active selection and queue reorder behavior must remain stable
- smart-switch behavior must be deterministic instead of depending on network return order
- the full suite must stay green after any arbitration change
