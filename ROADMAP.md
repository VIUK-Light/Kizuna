# Kizuna roadmap

This is a lightweight statement of current direction, not a promise that every
item will ship. Priorities can change after design or safety review. Please
open an Issue before starting a large change.

## Now

- Persona and Story reliability, data integrity, and recovery
- Accessibility and responsive UI behavior
- Local/remote model configuration safety and credential handling
- OSS onboarding, documentation, and a healthy default branch

## Next

- Import/export and recovery workflows that are easier to inspect
- More focused tests for persistence races, safety boundaries, and UI flows
- Contract fixtures and a first client-independent Character/Persona vertical slice for the accepted [Web-first design](docs/architecture/web-client-plan.md)
- Regional review and platform adapters for the [age-tier safety foundation](docs/architecture/age-safety-policy.md)

## Later / exploring

- A self-hostable Web client/API preview as the first Windows/Linux/ChromeOS access path
- Broader runtime and provider support
- Account or synchronization features with explicit privacy boundaries
- Hosted-service age assurance, consent, and guardian flows after product, privacy, and legal review

## How to choose work

The open Issue backlog is not itself a release plan. Start with good first
issue or help wanted, and confirm scope in the Issue before coding.
