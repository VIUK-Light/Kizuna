# Kizuna Work Status

Updated: 2026-08-15 JST

## Current branch

- Repository: `VIUK-Light/Kizuna`
- PR: [#263](https://github.com/VIUK-Light/Kizuna/pull/263)
- Branch: `codex/story-acceptance-runner-20260814`
- State: open, mergeable; latest review requested changes, rerun pending; not merged
- Actor: `VIUK-Codex-Bot`

## Completed before this update

- PRs #259–#262 are merged according to the current task ledger.
- Story acceptance runner, seed propagation, trace seam, JSONL evaluator, and
  CI checks are present.
- Initiative remains default-OFF.
- The official iori model is available on the SSD:
  `viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf`
- Official model identity: 3,416,118,624 bytes,
  SHA-256 `eafe6431810b2a2a17f6c4b0be338364440707e10ff6648d07665e10875039a5`.
- LM Studio generic Gemma 4 E2B Q4_K_M is a different artifact and is not
  valid for the formal VIUK iori gate.

## Current changes in PR #263

- Reload the persisted StorySession before `beginTurn` so the revision on disk
  and the app-path input match.
- Stage iori under the DEBUG acceptance root actually used by
  `KizunaDataMigration`.
- Copy and hash-check the model instead of using a symlink; Foundation file
  resource values see the symlink itself.
- Keep acceptance runtime identifiers filename-only and require the trusted
  iori filename/SHA for completed records.
- Prevent evaluation JSONL output under the repository.
- Resolve output-path and `SRCROOT` symlinks before containment checks, and
  reject duplicate acceptance selections after alias/seed normalization.
- Propagate XCTest task cancellation through `runTurn`, cancel the active
  StorySessionService, and avoid swallowing cancellation while waiting for a
  response.
- Write generation metadata and human-rating input to separate external JSONL
  files. `generations.jsonl` contains no raw response/context/state patch;
  `rating-input.jsonl` is local-only and initialized with mode `0600`.
- Require the evaluator to validate the one-to-one rating-input contract before
  blind artifact creation.

## Verification

- `xcrun swiftc -parse` for the changed Swift runtime and acceptance runner:
  passed.
- `xcodebuild -quiet build-for-testing` for the macOS KizunaAI scheme passed
  with the isolated temporary HOME; existing Swift concurrency warnings remain.
- `zsh -n tools/run_story_initiative_acceptance.sh`: passed.
- `git diff --check`: passed.
- Python evaluation unit tests: 12 passed.
- Full installable application build and the real 384-output matrix: not run
  yet.

## Blockers

- The official-model local canary now passes persistence and artifact
  discovery, but the bundled `llama-server` health endpoint repeatedly refuses
  connections. The runner records errors, not completed generations.
- A ready failure after a successfully launched server now stops immediately
  after preserving stderr, instead of retrying the same runtime up to 16 ports;
  the remaining binary/health failure is still unresolved.
- LM Studio can load `viuk-story-v2.5@q4_k_m` (the same trusted 3.42 GB
  artifact), but one minimal local `/v1/chat/completions` request remained in
  `PROCESSINGPROMPT` and timed out after 120 seconds. The diagnostic model was
  unloaded afterward; this is not formal GO evidence and no external API was
  used.
- The 384-output formal run is not GO evidence yet.
- NAGI/Google API evaluation is paused until the user explicitly authorizes
  sending Story fixtures/prompts to the external API.
