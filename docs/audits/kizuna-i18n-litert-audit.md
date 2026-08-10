# Kizuna translation and LiteRT-LM audit

Date: 2026-08-10<br>
Audited base: `1d3d2b3` (`main`)<br>
Scope: source, seed data, vendored LiteRT-LM v0.14.0 wrapper, and the current
publisher metadata for Kizuna's configured default model. This is not an iPhone
execution result.

Run the reproducible source scan with:

```sh
python3 tools/audit_kizuna_i18n.py
```

`--strict` deliberately exits non-zero while the findings below exist. Do not
wire it into required CI until the remediation is complete.

## #8 — Translation completeness

`KizunaAI/Localizable.xcstrings` has 405 non-empty keys. Five have no English
string unit:

- `%@ / 2`
- `Kizuna`
- `Lorebook・キャラ同士の関係・タグ（必要なときだけ）`
- `VIUK 絆 / PROFILE`
- `詳細設定`

At this base, exact source searches find no live use of the first, second, or
fourth key; the latter two visible call sites choose English through
`KizunaCopy.text` directly. They are therefore stale catalog debt rather than
observed fallback text, but the catalog should still be made complete or have
the unused keys removed.

There are live, user-visible Japanese literals outside the localization path:

- `CharacterCreateView` has the warn/block alert titles and actions, plus the
  relationship label.
- `MockCharacterSafetyChecker` produces six Japanese reasons, and the save
  failure path produces one more. `CharacterCreateView` renders those reasons
  directly in its alerts.

### Required fix shape

Use `KizunaCopy.text` for fixed controls. For safety decisions, retain a stable
reason code in the domain layer and render the localized explanation in the
view/presentation layer. Do not translate or rewrite text that the user typed
into a character, a custom story, or a conversation.

## #12 — LiteRT-LM Swift 6 concurrency

`LocalAssistantLiteRTLMRuntime` requests Swift's concurrency guarantees while
holding `Conversation` in an `NSLock`-guarded `@unchecked Sendable` box.
`Conversation` in the vendored LiteRT-LM wrapper is a mutable class, not a
Sendable type. The runtime also crosses MainActor/nonisolated boundaries to
install, clear, and cancel the same instance.

This is more than a diagnostic problem:

- `Conversation.sendMessage` calls the native blocking
  `litert_lm_conversation_send_message` API.
- The native `litert_lm_conversation_cancel_process` documentation describes
  cancellation of asynchronous inference.
- The current app therefore relies on cancellation behavior that is not stated
  for its blocking send path.

Do not suppress this with `@preconcurrency import` or another broad
`@unchecked Sendable` annotation. A safe minimum needs a LiteRT-LM wrapper
contract that explicitly covers handle ownership and cancellation concurrency,
then an app-level serial owner for each conversation. The likely runtime path
is `sendMessageStream`, since it maps to the native asynchronous API; its
termination must cancel the native operation and release the retained stream
context exactly once.

Required regression tests:

1. cancel during prefill/decode;
2. app background transition during generation;
3. cancel A followed immediately by start B; and
4. cancellation while another request waits at the execution gate.

## #21 — Model context limit

The values below answer different questions and must not be conflated.

| Evidence | Value | Meaning |
| --- | ---: | --- |
| Current model card | 32,768 | Publisher-declared maximum model context |
| Kizuna `EngineConfig.maxNumTokens` | 2,048 | App-requested KV-cache budget |
| Kizuna `maxOutputTokens` | 1,024 | Per-conversation generation cap |
| Historical device error | 1,280 | Runtime-enforced limit observed in that log |
| Historical `max_tokens` log | 784 | Not enough evidence to identify it as context capacity |

The configured URL points at a moving `main` revision of
[`gemma-4-E2B-it.litertlm`](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/blob/main/gemma-4-E2B-it.litertlm).
The model card reports 2,048-token benchmark runs and support for up to 32K
context, but that is not proof of the exact model installed on a phone.

The current downloader validates extension and approximate size; it does not
pin and verify the model's SHA-256. Therefore a size match cannot establish the
model revision that produced the 1,280-token error.

The source budgeter also has two correctness gaps:

1. after eight compression attempts it logs an over-budget count and still
   returns the candidate for sending; and
2. it tokenizes a hand-built `system/user` string, while LiteRT-LM adds the
   actual conversation template later.

### Device confirmation protocol

Before declaring a value final, record on the actual iPhone:

1. model filename, byte count, SHA-256, source revision, and LiteRT-LM version;
2. requested `maxNumTokens` and `maxOutputTokens`;
3. token count of the *rendered Conversation prompt*, including system and
   history template overhead; and
4. a binary-search canary through the real Conversation API, retaining the
   native error for the first failing input.

The runtime must reject an over-budget request before calling the native API.
It should derive the output budget from the measured prefill count and an
explicit guard band, rather than assuming that an input byte cap proves token
safety.

## #62 — Japanese remaining in English story detail

The existing English presentation layer handles some `StoryWorld` fields but
does not localize the entire detail model.

- `StoryWorldLocalization` lacks `safetyRules`; `rulesCard` displays the stored
  Japanese safety/output rules.
- The `displayedScene` fallback only applies when a scene summary exactly equals
  `world.openingScene` (or is blank and first). None of the 71 bundled initial
  scenes satisfies either condition, so all 71 remain Japanese in English
  detail.
- All 141 bundled characters have a `storyRelationshipToUser` value. The cast
  card displays it verbatim.
- The character spotlight has five fixed Japanese labels and shows the bundled
  Japanese character body fields verbatim.
- Only 24 titles have a detailed English body catalog, but only 12 of those are
  present in the 71 current seeds. The other 59 seeded stories use generic
  English prose; this avoids raw Japanese for several
  world fields but is not a translation of the underlying story.

### Required fix shape

Introduce a presentation-only system-story localization keyed by a stable
system story identifier, not a mutable display title. It needs translations for
world safety rules, every displayed scene field, cast relationship text, and
character-detail fields. Keep the `Codable` saved source data unchanged.

For user-created stories and model/user messages, preserve the original text.
If the product wants a translation feature later, it must be explicit, opt-in,
and separate from the persisted original.

Acceptance tests should enumerate all 71 bundled stories in English mode and
assert that every system-owned displayed field is English, while Japanese mode
and persisted JSON remain byte-for-byte unchanged.
