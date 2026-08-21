# Contributing to Kizuna

[日本語](CONTRIBUTING.md)

Thank you for your interest in Kizuna. Small fixes, documentation changes,
reproduction steps, and design proposals are welcome.

## Community expectations

- Respect user agency, privacy, and real-life relationships.
- Do not publish API keys, access tokens, cookies, private URLs, personal
  conversation history, or model files.
- Anonymize or summarize logs and conversation examples.
- Attacks, discrimination, and harassment are not acceptable. See
  CODE_OF_CONDUCT.md.

## Contribution flow

1. Discuss large features or architecture changes in an Issue first.
2. Fork the repository and create a short, purpose-oriented branch name.
3. Keep one primary purpose per Pull Request.
4. Run the build, tests, and manual checks relevant to your change.
5. Complete the Pull Request template and state anything you could not verify.

Prefer reviewable changes. Do not mix a large refactor with an unrelated
feature. Do not commit generated files, DerivedData, model caches, or personal
Xcode settings.

## AI-assisted changes

AI-assisted contributions are welcome, but the submitter is responsible for
understanding and checking the change's behavior, safety, and licensing.
State whether AI assistance was used, the main tool or model, and what you
personally verified in the Pull Request description. Unexplained bulk-generated
changes may be declined.

## Development environment

- macOS
- Xcode 26.1 or later
- XcodeGen
- iOS 26.0 / macOS 26.0 or later

If project.yml changes, regenerate the project with: xcodegen generate

Unsigned verification builds use the macOS and iOS Simulator destinations
described in CONTRIBUTING.md.

## Internationalization

Follow docs/i18n.md. New user-facing copy belongs in the String Catalog;
existing KizunaCopy.text uses may be migrated when the surrounding screen is
changed.

## License and onboarding

Review LICENSES.md before adding third-party code, images, models, data, or
creative content. Start with the open
good first issue and help wanted lists, then check ROADMAP.md. Large
persistence, security, AI runtime, Web, and platform changes require an Issue
discussion before implementation.
