# Age-tier safety and privacy boundary

Status: conservative application foundation; regional compliance review still
required

Tracks: [#450](https://github.com/VIUK-Light/Kizuna/issues/450)

Last updated: 2026-08-21

## Scope

Kizuna separates three inputs that must not be collapsed into one number:

1. a Character's `SafetyRating`;
2. the user's coarse `UserAgeTier` and separate `AgeAssuranceLevel`; and
3. risks detected in the current input or output as `SafetyDomain` values.

These inputs produce one `EffectiveSafetyPolicy` before Persona or Story calls
any local or remote model. Character Library uses the same policy for
availability. This is a product-safety control, not proof of age, parental
consent, or legal eligibility.

## Data minimisation

The app stores only:

- `unknown`, `child`, `teen`, or `adult`; and
- how that tier was obtained, such as `selfDeclared` or `platformDeclared`.

The default is `unknown`. Kizuna does not ask for or persist a date of birth,
an identity document, evidence used by an age-assurance provider, or a derived
exact age. Selecting `unknown` removes the saved age-safety value. The value is
kept in device-local `UserDefaults`; it is not added to the user-profile prompt
and is not sent to a model provider. Models receive only abstract safety rules.

Self-declaration is recorded as self-declaration and must not be described as
verified. A future platform adapter may supply a platform-declared range and
assurance source, but must still avoid storing the underlying evidence.

## Conservative defaults

- `unknown` and `child` allow General-rated Characters.
- `teen` allows General and Teen-rated Characters.
- `adult` also allows Sensitive-rated Characters.
- Restricted-rated Characters are unavailable for every tier.
- Age-independent boundaries for real-world danger, illegal assistance,
  privacy invasion, harassment, and manipulative dependency remain active for
  adults.
- Unknown age uses the stricter default and never unlocks age-dependent
  content.

Rating is not used as a simple severity number for conversation decisions.
Domain rules are evaluated separately, so a sensitive health context is not
treated identically to an explicit-content context.

## Shared enforcement path

```text
coarse age tier + assurance source
                 +
Character SafetyRating + detected SafetyDomains
                 |
                 v
       EffectiveSafetyPolicy
          /       |       \
Character list  Persona  Story
                    |
          local or remote provider
```

`SafetyPipeline` applies the policy to character, input, and output decisions.
Prompt rules are deduplicated before generation. Availability and input policy
run before provider selection; generated output passes through the same policy
before persistence. Switching between a local model and a remote provider
therefore cannot weaken the application decision.

## Non-destructive tier changes

Changing or clearing the tier does not modify Character, Persona, Story, or
Memory repositories. Content that is unavailable under the current policy is
filtered or blocked at use time. If the policy later permits it, the original
data becomes available again. Delete and export remain separate explicit user
actions.

## Age assurance and regional gates

The in-app picker is a neutral self-declaration for content safety only. Before
a hosted service, child-directed distribution, parental-consent flow, or
legally age-gated feature ships, maintainers must determine applicable regions,
lawful basis, consent and guardian flows, retention, and appeal/correction
paths with qualified review.

On supported Apple platforms, a future adapter should prefer the Declared Age
Range API over collecting a birth date. The adapter must:

- request only ranges needed by the product;
- preserve the declaration/assurance source;
- respect platform parental controls and a declined response;
- use region-provided ranges without inferring an exact age; and
- keep `unknown` as the fallback when no reliable range is available.

The current foundation intentionally does not add the entitlement or claim
that self-declaration satisfies a regional age-assurance obligation.

## Verification matrix

Tests cover:

- every age tier against every `SafetyRating`;
- age-specific and age-independent domain actions;
- Unknown as a safe default;
- assurance persistence without a birth date;
- Character Library filtering without repository deletion; and
- identical policy application before local and remote routing.

## Primary references

- Apple, [Requesting people's age range information in your app](https://developer.apple.com/documentation/declaredagerange/requesting-people-share-their-age-range-with-your-app)
- US Federal Trade Commission, [Complying with COPPA: Frequently Asked Questions](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)
- UK Information Commissioner's Office, [Children's Code standards](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/childrens-information/childrens-code-guidance-and-resources/age-appropriate-design-a-code-of-practice-for-online-services/code-standards/)
- European Commission, [Safeguards for children's personal data](https://commission.europa.eu/law/law-topic/data-protection/information-business-and-organisations/legal-grounds-processing-data/are-there-any-specific-safeguards-data-about-children_en)

These references inform data minimisation and conservative defaults. They are
not a substitute for deciding which laws apply to a particular distribution.
