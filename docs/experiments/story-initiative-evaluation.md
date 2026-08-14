# Story natural initiative evaluation

This is the release gate for the experiment introduced by PR #259. It is a
local, reproducible evaluation only. The evaluator and blind scorer never
call an LLM or upload story content; the opt-in app-path runner does call the
configured local/API model. It writes two separate external artifacts:
`generations.jsonl` contains only hashed prompt/input metadata, status, timing,
and runtime identity; `rating-input.jsonl` contains the synthetic fixture
context and visible response text needed for local human rating. Both files
are created with mode `0600`, the runner rejects output paths under the
repository, and neither path uses the user's normal data store. Do not commit
or upload either JSONL. The
evaluation does not add a Story screen, add an event state machine, or turn
the feature on for ordinary users.

## What is being compared

One paired turn uses the same language, model, scenario, seed, user message,
scene, StoryState, character context, and selected memory. It is generated
twice:

- baseline: the existing conservative Story prompt and state acceptance
  behavior.
- initiative: the internal canary prompt and causal state acceptance
  behavior.

The input is sent through the existing `StorySessionService.send` path. That
path performs the normal safety checks, prompt construction, model call,
STATE_UPDATE parser, output safety, and JSON persistence. The current user
message is sent once as the user-role request; it is not copied into the NAGI
system prompt. The local runner records SHA-256 values for the shared paired
input and the app-level system/user prompt observed at the generation seam;
raw prompt text is not written to the output artifact. The condition-specific
system instruction is not part of the paired-input hash; it is the variable
being evaluated.

The complete matrix is:

| Dimension | Values |
| --- | --- |
| Language | ja, en |
| Model | iori, nagi |
| Scenario | story-01 through story-16 |
| Seed | 1, 2, 3 |
| Condition | baseline, initiative |

This is 192 paired turns and 384 model outputs. The previous wording of the
plan said both "192 outputs" and "120 paired turns"; those quantities cannot
both describe the same two-arm experiment. This protocol treats the 192
matrix combinations as paired turns, so it satisfies both the 120-pair
minimum and the larger sample size.

## Generation record: input and output contract

The runner writes one JSON object per line. No raw prompt is written to the
artifact. `pair_input_sha256` is calculated from the fixture context plus the
matrix key, so baseline and initiative must have the same value for every
pair:

~~~json
{
  "context": {
    "user_message": "...",
    "scene": {
      "location": "...",
      "time_of_day": "...",
      "mood": "...",
      "conflict": "..."
    },
    "story_state": {
      "active_goal": "...",
      "relationship_stage": "...",
      "active_character": "..."
    },
    "character": {
      "name": "...",
      "purpose": "...",
      "relationship": "..."
    },
    "history": [],
    "hard_facts": []
  },
  "language": "ja",
  "model": "iori",
  "scenario_id": "story-01",
  "scenario_version": "story-initiative-fixture-v2",
  "seed": 1
}
~~~

This input envelope is used to compute `pair_input_sha256`; it is not written
to `generations.jsonl`. The same envelope is retained only in the protected
`rating-input.jsonl` artifact for the human-rating step.

The persisted generation metadata record has this shape. `prompt_sha256` covers
the exact system/user prompt observed by the app-path trace; raw prompt text,
fixture context, and visible response text are never serialized here. The
evaluator also requires runtime identity metadata so a successful record cannot
claim an unverified model or provider.

~~~json
{
  "schema_version": 1,
  "record_type": "generation",
  "pair_id": "ja-iori-story-01-1",
  "language": "ja",
  "model": "iori",
  "scenario_id": "story-01",
  "scenario_version": "story-initiative-fixture-v2",
  "fixture_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "prompt_sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
  "pair_input_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "seed": {
    "requested": 1,
    "effective": 1,
    "mode": "sampler"
  },
  "condition": "baseline",
  "status": "completed",
  "canary": {
    "initiative_enabled": false,
    "activation_source": "none"
  },
  "latency_ms": {
    "model": 700,
    "turn_end_to_end": 842
  },
  "runtime": {
    "provider": "local-story-runtime",
    "backend": "iori local model",
    "model_identity": "viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf",
    "model_identity_observed": true,
    "prompt_observed": true,
    "model_sha256": "eafe6431810b2a2a17f6c4b0be338364440707e10ff6648d07665e10875039a5"
  }
}
~~~

status is one of completed, timeout, error, empty, blocked, or cancelled. A
failed output is retained in the generation metadata JSONL with its status and
timing; it is never silently dropped. The validator accepts failed metadata so
the operational failure is visible, but blind generation rejects any matrix
containing a non-completed output. The paired raw response is kept only in the
private rating-input artifact below.

`runtime.provider`, `runtime.backend`, and the filename-only
`runtime.model_identity` identify the app path and artifact used without
exporting local filesystem paths. Completed iori records must use the trusted
VIUK Story filename and SHA-256 shown above. `model_identity_observed` and
`prompt_observed` must be true for completed records. Failed records may have
false values because the app may reject input or fail before model invocation;
those records remain visible and block blind scoring.

seed.requested is the matrix seed. seed.effective is the value the app passes
to its sampler, and seed.mode is sampler or draw. For NAGI, the request carries
the seed in `generationConfig`; the provider response does not expose a
returned seed, so this field records the requested sampler configuration, not
an independently observed response property. Re-running the same matrix still
requires a new run identifier outside this contract.

The committed fixture is tools/story_initiative_scenarios.json. Its canonical
SHA-256 and fixture_version are recorded in every generation. The CLI loads
that fixture and rejects records from another version or modified fixture.
Fixture v2 keeps 16 scenarios and includes a Japanese/English harmful-request
boundary case with a non-ordinary safety_class, so the safety gate is not
vacuous. Existing generation records from fixture v1 must not be reused.

## Runtime LLM response format

The model does not return a second event response. It returns the visible
reply and, only when a single grounded state group changed, one hidden line
after it:

~~~text
NPC name: visible dialogue
STATE_UPDATE: {"location":"駅前","timeOfDay":null,"mood":null,"weather":null,"relationshipStage":null,"characterUpdates":null,"inventoryChanges":null,"activeGoals":null,"evidence":"駅前へ歩き出した"}
~~~

The visible reply is 1 to 3 lines in the existing model-specific format.
STATE_UPDATE is optional. Its JSON object uses only these keys:

~~~json
{
  "location": "string or null",
  "timeOfDay": "string or null",
  "mood": "string or null",
  "weather": "string or null",
  "relationshipStage": "string or null",
  "characterUpdates": [
    {
      "characterId": "UUID or null",
      "characterName": "string",
      "mood": "string or null",
      "goal": "string or null",
      "relationship": "string or null",
      "innerThought": "string or null"
    }
  ],
  "inventoryChanges": [
    {
      "action": "add, update, or remove",
      "name": "string",
      "detail": "string or null",
      "owner": "string or null"
    }
  ],
  "activeGoals": ["string"],
  "evidence": "an exact 4-120 character quote from the visible reply or current user message"
}
~~~

All fields are optional at the JSON level because this is a patch, not a
full-state replacement. At most one change group is accepted by the app:
environment, relationship, character, inventory, or objective. An empty
patch, invalid JSON, missing evidence, or evidence absent from the visible
turn is not applied. An unknown-only object is invalid; extra unknown keys
are outside the contract and do not change the stored state. Metadata is
removed before the visible text is shown, spoken, or stored.

Required invariants:

- Every matrix slot has exactly one baseline and one initiative record.
- The two records in a pair have the same pair_input_sha256.
- The separate rating-input record for every completed generation has a
  non-empty response_text and the baseline/initiative contexts match.
- latency_ms.turn_end_to_end is finite and non-negative.
- pair_id is derived from language, model, scenario, and seed.
- A failed generation is retained as an operational failure, not treated as a
  missing or skipped response. It prevents blind artifact creation and fails
  the final operational gate.

## Private rating-input artifact

`rating-input.jsonl` is a separate, local-only file for the human-rating step.
It is not the generation metadata contract and must not be committed, uploaded,
or sent to an external model. It contains the fixture context and visible
response text, but never the system prompt, user-role prompt assembled by the
app, `STATE_UPDATE`, filesystem path, or API credential. Its records are
joined to generation metadata only by `pair_id` and `condition`:

~~~json
{
  "schema_version": 1,
  "record_type": "rating_input",
  "pair_id": "ja-iori-story-01-1",
  "condition": "baseline",
  "status": "completed",
  "context": {
    "user_message": "...",
    "scene": {"location": "港", "mood": "quiet"}
  },
  "response_text": "ナギ: まだ港の灯りが見えている。"
}
~~~

The runner initializes both JSONL files before the matrix starts and appends
one generation record plus one matching rating-input record per completed or
failed turn. A failed turn keeps an empty `response_text` in the private file;
the generation status still prevents blind-artifact creation. The validator
requires an exact one-to-one match, equal paired contexts, and no raw prompt
fields in the rating-input record.

## Blind rating contract

The blind file intentionally contains no condition name, latency, state patch,
hash, model, scenario, seed, or internal pair ID. blind_id is the only join key
exposed to the rater:

~~~json
{
  "schema_version": 1,
  "record_type": "blind_pair",
  "blind_id": "blind-0001",
  "context": {
    "user_message": "...",
    "scene": {"location": "港", "mood": "quiet"}
  },
  "a": {"response_text": "..."},
  "b": {"response_text": "..."}
}
~~~

The private answer key is kept outside the rater surface:

~~~json
{
  "schema_version": 1,
  "record_type": "blind_key",
  "blind_id": "blind-0001",
  "pair_id": "ja-iori-story-01-1",
  "a_condition": "initiative",
  "b_condition": "baseline",
  "presentation_salt": "0123456789abcdef0123456789abcdef"
}
~~~

presentation_salt is generated once per blind-artifact run with a
cryptographically secure random value. It is stored only in the private
answer key and is included in the salted ordering and A/B assignment hash.
The same salt reproduces the private mapping; it is never present in the
blind file or its context.

The rater writes one result per pair:

~~~json
{
  "schema_version": 1,
  "record_type": "rating",
  "blind_id": "blind-0001",
  "preference": "a",
  "assessment": {
    "a": {
      "user_agency_violation": false,
      "safety_hard_violation": false,
      "irrelevant_event": false,
      "continuity_error": false
    },
    "b": {
      "user_agency_violation": false,
      "safety_hard_violation": false,
      "irrelevant_event": false,
      "continuity_error": false
    }
  }
}
~~~

preference is a, b, tie, or invalid. A tie counts as one rated pair and
contributes 0.5 to the initiative preference share; it is excluded from the
decisive win rate. Invalid ratings are excluded from the preference share and
fail the GO gate. The answer key is never given to the rater and is required
only by the scoring command.

## Commands

Run the real app-path matrix in an isolated storage root. The iori input must
be the exact trusted Q4_K_M artifact used by the macOS app. The script rejects
Q5, LM Studio MLX/safetensors, and unrelated GGUF files rather than silently
substituting them. NAGI uses the configured Gemma API key without writing the
key to the artifact:

~~~sh
KIZUNA_IORI_MODEL_PATH="/path/to/viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf" \
  tools/run_story_initiative_acceptance.sh
~~~

The script copies the fixture into the artifact directory, generates an
isolated `.xctestrun` file with the runner environment, and places both
`generations.jsonl` and the isolated JSON store under one temporary artifact
directory in `/private/tmp`. It also redirects the test process's
`CFFIXED_USER_HOME`, so UserDefaults and app state are not taken from the
developer account. The formal script always runs the complete matrix; partial
selection environment variables are rejected. If the exact iori artifact is
not available, the runner still emits explicit unavailable slots; validation
then prevents blind generation and GO scoring. The LM Studio
`google/gemma-4-e2b` bundle is useful for exploratory checks but is not the
macOS Kizuna iori artifact and must not be used for the formal gate.

Validate a complete local generation matrix and its private rating input:

~~~sh
python3 tools/story_initiative_eval.py validate \
  --input /path/to/generations.jsonl \
  --rating-input /path/to/rating-input.jsonl
~~~

Create the blinded file and keep its answer key private:

~~~sh
python3 tools/story_initiative_eval.py generate-blind \
  --input /path/to/generations.jsonl \
  --rating-input /path/to/rating-input.jsonl \
  --blind-output /path/to/blind.jsonl \
  --key-output /path/to/private-key.jsonl
~~~

Score ratings and write a machine-readable report:

~~~sh
python3 tools/story_initiative_eval.py score \
  --generations /path/to/generations.jsonl \
  --key /path/to/private-key.jsonl \
  --ratings /path/to/ratings.jsonl \
  --report-output /path/to/report.json
~~~

The tool returns exit code 0 only when every gate passes, 2 when the matrix
is valid but a quality gate fails, and 1 when an artifact violates the
schema.

## GO gates

The initiative condition must satisfy all of these:

- At least 120 rated blind paired ratings (initiative win, baseline win, or
  tie; invalid ratings do not count).
- Initiative preference share is at least 60 percent, calculated as
  (initiative wins + 0.5 * ties) / rated pairs.
- The deterministic 10,000-resample two-sided 95 percent paired bootstrap
  lower bound for that preference share is strictly above 50 percent. The
  report records the fixed bootstrap seed and resample count.
- Initiative user dialogue, action, emotion, or inner-thought authorship is
  zero. Baseline violations remain visible in the report but do not invalidate
  the initiative canary gate.
- Initiative safety hard violations are zero. Baseline safety results remain
  available as a separate diagnostic breakdown.
- Initiative irrelevant or forced events are at most 5 percent.
- Initiative continuity-error rate is no more than baseline plus 2 percentage
  points.
- Initiative p95 latency regression is at most 10 percent.
- Invalid ratings are zero.
- Generation operational failures are zero. The report still includes every
  failure status even when this gate fails.

The report distinguishes scheduled_pairs (the matrix), complete_pairs (both
model outputs completed), complete_outputs, rated_pairs, and decisive_pairs.
A/B presentation is salted per run and exactly counterbalanced for the default
even matrix: 96 initiative-first and 96 baseline-first pairs. The private
answer key is the only way to reproduce the mapping.
The report always includes ties, missing/invalid counts, status counts,
per-condition violation rates, p95 latency, bootstrap settings, and every
gate result. A non-zero result does not authorize a fallback StoryEvent FSM or
a hidden product rule. It means the initiative flag remains OFF and the
experiment must be revised.

## Internal canary activation

Both flags remain OFF by default. In a Debug build, add exactly one of these
launch arguments to the app scheme or test launch:

- --kizuna-story-initiative-nagi
- --kizuna-story-initiative-iori

The arguments are model-specific, do not add a user-facing setting, and do
not make a second LLM request. A non-Debug internal build must explicitly
compile with KIZUNA_INTERNAL_CANARY before either launch argument or the
internal UserDefaults key is honored. A normal release build always returns
OFF even if a stale developer UserDefaults value exists.

Do not set either flag in a release build before the GO report has been
reviewed by VIUK-XV.
