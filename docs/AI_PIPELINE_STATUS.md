# AI pipeline implementation status

This page is the source-of-truth summary for the lightweight AI components used
by the production Character and Story paths. A component is not called
"model-backed" merely because it has a protocol: the production composition
must route it through the local auxiliary model and must expose an explicit
failure behavior when that model is unavailable.

## Current composition

| Component | Production path | No executable local artifact |
| --- | --- | --- |
| Character, input, and output safety | `SafetyPipeline.shared` uses `RuntimeCharacterSafetyChecker`, `RuntimeInputSafetyChecker`, and `RuntimeOutputSafetyChecker`. Their structured local-model result is merged with the rule checker without lowering an existing decision. | The rule checker remains the fail-closed boundary. Invalid model output is discarded. |
| Safety concern classification | `ContextualSafetyConcernClassifier` uses weighted context and urgency signals. | The classifier returns no concern when the evidence is insufficient. |
| Lightweight classification | `RuntimeSmallModelClassifier` sends a label-and-confidence contract through the `classifier` role. | It returns an empty/low-confidence result; it does not fabricate a 270M result. |
| Memory selection | `RuntimeMemorySelector` asks the `memoryRetrieval` role for existing memory IDs only. | It returns no selection unless an explicitly injected fallback is provided. |
| Memory extraction | `RuntimeMemorySummarizer` asks the `memoryExtraction` role for one structured candidate. | It returns no new memory unless an explicitly injected fallback is provided. |
| Story cast selection | `RuntimeSceneCharacterSelector` asks the `sceneCharacterSelection` role for cast UUIDs and validates them against the current cast. | It keeps the current/first valid cast member; it does not invent IDs. |
| Story summary | `RuntimeSceneSummarizer` asks the `sceneSummary` role for a bounded summary. | It retains the existing summary. |
| Next-scene suggestions | `RuntimeNextSceneSuggester` asks the `nextSceneSuggestion` role for bounded structured candidates. | It returns no generated suggestions, leaving manual scene creation available. |

The historical `Mock*` implementations remain available for deterministic
tests, previews, and explicit dependency injection. They are not the default
composition for the shared production safety pipeline or the Character/Story
auxiliary services.

## Local model contract

The auxiliary path is local-only and uses the model selected for each role in
Advanced settings. Safety uses a five-line contract:

```text
ACTION=allow|warn|soften|block|requireEdit
DOMAINS=comma-separated SafetyDomain raw values
SEVERITY=info|warning|block
REWRITE=one safe replacement, or NONE
RULES=semicolon-separated prompt rules, or NONE
```

The parser rejects an invalid contract. Safety decisions are merged
fail-closed: a model result can add a risk domain or raise the action, but can
never downgrade a rule-based block or warning. A `.soften` result without a
rewrite is converted to `.requireEdit` by the shared rewrite contract.

## Remaining validation work

The production path is now model-capable, but model quality is still an
evaluation concern. Before treating the auxiliary model as a safety oracle we
need a versioned Japanese/English evaluation set covering negation, euphemism,
fictional context, self-harm, harassment, minors, personal information,
medical, financial, and legal domains. Until that evaluation gate passes, the
rule-based boundary remains enabled as a conservative guard.

The implementation is covered by the `RuntimeSafetyDecisionContract` tests and
the existing Character/Story safety, memory, routing, and persistence tests.
