# Kizuna Decisions

## Product

- PersonaChat remains; Story is not a replacement for the existing
  conversation data.
- Natural initiative is expressed through the existing narration and character
  reply. Do not add cards, labels, progress UI, a separate mode, or a fixed
  event state machine.
- Initiative is allowed only when grounded in the current Story context and
  must not speak for the user or force a goal.
- The feature stays default-OFF until the paired evaluation passes its release
  gate.

## Brand

- The product display name is `Kizuna` in both Japanese and English UI.
  `AppBrand` (`KizunaAI/App/AppBrand.swift`) is the single source of truth for
  the display name, bundle name (`KizunaAI`), bundle identifier
  (`com.viuk.KizunaAI`), and Keychain service name.
- `KizunaCopy.appName` delegates to `AppBrand.displayName`, so UI app-name
  labels are never spelled `kizuna` (lowercase) or `KizunaAI`.
- `project.yml` and `KizunaAI/Info.plist` must keep `CFBundleDisplayName` in
  sync with `AppBrand.displayName` (currently `Kizuna`).
- The persona/character chat feature is branded `絆` in Japanese and `Kizuna`
  in English (e.g. `絆チャット` / `Kizuna chat`). It is a feature name, not the
  app name, and is not routed through `AppBrand`.

## Evaluation

- The formal iori artifact is the exact VIUK Story Q4_K_M file and SHA recorded
  in `tools/run_story_initiative_acceptance.sh`; a generic LM Studio Gemma file
  is a separate compatibility comparison, never a substitute.
- A green XCTest wrapper is insufficient. A completed record requires an
  observed runtime identity, observed prompt, trusted iori filename, and
  trusted iori SHA-256.
- LM Studio is useful as a local runtime comparison, but its successful model
  load does not prove Kizuna's app-path runtime works. The trusted Q4 model
  loaded there, while a minimal local completion timed out in
  `PROCESSINGPROMPT`; keep this separate from the formal gate.
- Acceptance output is an external local artifact. Raw prompt text is not
  serialized into generation metadata. Generated response text and fixture
  context are retained only in a separate `rating-input.jsonl` with local
  `0600` permissions for human rating, and must not be committed or uploaded.
- Generation metadata and rating input are appended as a pair per turn. The
  evaluator rejects missing, duplicate, mismatched, or prompt-bearing rating
  records before blind artifact creation.
- Acceptance task cancellation is a control-flow failure, not an evaluation
  sample: the runner cancels the active StorySessionService and rethrows
  `CancellationError` instead of recording a partial turn.
- Failed, blocked, empty, and timeout records remain visible and prevent blind
  scoring.

## Collaboration

- Work sequentially in one PR branch to avoid merge conflicts.
- Codex prepares and pushes changes as `VIUK-Codex-Bot`; VIUK-XV reviews and
  performs the merge.
- Never run the NAGI/Google API matrix without explicit external-data
  authorization.
