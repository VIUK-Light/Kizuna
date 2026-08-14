# Kizuna Work Status

Updated: 2026-08-15 JST

## Current branch

- Repository: `VIUK-Light/Kizuna`
- PR: [#263](https://github.com/VIUK-Light/Kizuna/pull/263)
- Branch: `codex/story-acceptance-runner-20260814`
- State: open, mergeable, approved; not merged
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

## Verification

- `xcrun swiftc -parse` for the changed Swift runtime and acceptance runner:
  passed.
- `zsh -n tools/run_story_initiative_acceptance.sh`: passed.
- `git diff --check`: passed.
- Python evaluation unit tests: 11 passed.
- Full application build: intentionally not run for this evaluation step.

## Blockers

- The official-model local canary now passes persistence and artifact
  discovery, but the bundled `llama-server` health endpoint repeatedly refuses
  connections. The runner records errors, not completed generations.
- The 384-output formal run is not GO evidence yet.
- NAGI/Google API evaluation is paused until the user explicitly authorizes
  sending Story fixtures/prompts to the external API.
