# Kizuna Story Initiative Work Plan

## Objective

Kizuna keeps PersonaChat and the existing Story experience. The experiment
adds only grounded, optional natural movement inside an ordinary Story turn.
There is no new event card, event screen, fixed-turn FSM, or automatic extra
LLM call.

## Release gate

- Compare baseline and initiative with the same input: ja/en × iori/NAGI ×
  16 scenarios × 3 seeds × 2 conditions.
- Collect at least 120 valid paired turns and 384 planned outputs.
- Require preference lower bootstrap bound > 50%, user-agency violations 0,
  safety violations 0, irrelevant events <= 5%, continuity regression <= 2
  points, p95 latency <= 10 seconds, and zero operational failures.
- Keep initiative default-OFF until the complete evidence and human rating
  report are available.

## Execution order

1. Keep the current PR sequence linear; do not open a second overlapping PR.
2. Verify persistence, parser, prompt, and runtime identity seams.
3. Run an isolated iori canary with the exact trusted VIUK Story GGUF.
4. Run the formal local matrix only after iori produces real completed records.
5. Request explicit authorization before any NAGI/Google API run because Story
   fixtures and prompts would leave the device.
6. Publish the evidence and update the release decision; the user merges.

## Working rules

- GitHub write actions use `VIUK-Codex-Bot`
  (`148663275+VIUK-Codex-Bot@users.noreply.github.com`).
- Do not merge automatically. Ask VIUK-XV to review and merge.
- Use one PR at a time and rebase/pull only after the preceding PR is merged.
- Do not treat a passing XCTest wrapper as generation success; validate the
  JSONL records and the runtime observation fields.
