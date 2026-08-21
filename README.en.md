# Kizuna

[日本語](README.md) | English

**A SwiftUI app for building relationships and stories with AI characters while respecting user agency and real life.**

Kizuna is an open-source character AI application for iOS and macOS. It supports persistent conversations, relationships, and stories while aiming to preserve expressive character experiences without optimizing for dependency or isolation from real-world relationships.

<img width="1179" height="2556" alt="C5BF1352-4849-48C7-BEC7-887E6B52308D" src="https://github.com/user-attachments/assets/615d6ac6-bcad-487f-b8c7-7687f35bc2b9" />
<img width="1320" height="2868" alt="Simulator Screenshot - iPhone 17 Pro Max - 2026-08-07 at 08 07 07" src="https://github.com/user-attachments/assets/52ace9ab-ceeb-4f18-879d-91eebba8ce9b" />


> Kizuna is designed neither to control users nor to push them away.

## Highlights

- **Persistent character relationships and stories** — More than a one-off chatbot; Kizuna handles worlds, memories, and relationship continuity.
- **Safety that preserves character consistency** — Necessary safety behavior should not collapse every character into the same refusal message.
- **Not designed for dependency** — Maximizing screen time, retention, or exclusivity is not a product goal.
- **User-controlled AI** — Conversations, memories, models, endpoints, and secrets are designed to remain manageable by the user.
- **Local and remote model support** — The interface and inference runtime are separated from individual model providers.
- **Native SwiftUI experience** — Shared product flows for iOS and macOS.

## Safety approach

Many safety systems react to isolated keywords and discard the surrounding creative or conversational context. Kizuna aims to distinguish fiction, role-play, and real-world risk, then respond proportionally.

- Avoid interrupting ordinary creative or intimate conversations unnecessarily.
- When real-world danger may be present, preserve a natural character response while adding access to trusted support resources.
- Avoid repeated language that encourages isolation or dependency, such as asking users to ignore other people or never close the app.
- Remain transparent that the character is AI and that its answers may be wrong.
- Do not make unnecessary collection of private conversations the price of immersion.

## Project status

Kizuna is under active development. Feature proposals, bug reports, documentation improvements, and Pull Requests are welcome.

## Supported platforms and installation

The official clients currently target iOS and macOS. Kizuna does not currently provide Windows, Linux, Android, or Web clients, and no prebuilt end-user release is available yet.

Until a downloadable release is published, Kizuna can be tried by building from source on a supported macOS development environment. If you are not setting up a development environment, see the [public roadmap](ROADMAP.md) for the direction of future distribution and Web support.

| Item | Current requirement |
| --- | --- |
| Development | Xcode 26.1 or later / XcodeGen |
| Planned platforms | iOS 26.0 / macOS 26.0 or later |
| UI | SwiftUI |
| Local inference | llama.cpp / LiteRT-LM |
| Secret storage | Keychain |

## Generate and build

```sh
xcodegen generate
```

Unsigned macOS verification build:

```sh
xcodebuild \
  -project KizunaAI.xcodeproj \
  -scheme KizunaAI \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Unsigned iOS Simulator verification build:

```sh
xcodebuild \
  -project KizunaAI.xcodeproj \
  -scheme KizunaAI \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Project structure

```text
KizunaAI/
├── App/                       # Startup, settings, and workspace
├── AI/
│   ├── CharacterLibrary/      # Characters, memories, stories, and safety
│   ├── PersonaChatService.swift
│   ├── LocalAssistantModelManager.swift
│   └── LocalAssistantRuntimeBridge.swift
├── Security/                  # Keychain integration
├── ThirdParty/                # llama.cpp / LiteRT-LM
└── project.yml                # XcodeGen configuration
```

## Contributing

Read [CONTRIBUTING.en.md](CONTRIBUTING.en.md) and the [public roadmap](ROADMAP.md) before opening an Issue or Pull Request. Small entry points are listed through [good first issue](https://github.com/VIUK-Light/Kizuna/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) and [help wanted](https://github.com/VIUK-Light/Kizuna/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22).

Issues and Pull Requests should include, where possible:

- Reproduction steps, expected behavior, and actual behavior
- iOS / macOS, device / Simulator, OS, and Xcode versions
- Model format and whether local or remote generation was used
- Logs or screenshots with API keys and personal information removed

Do not publish conversation history, API keys, access tokens, private URLs, or other secrets.

## License and third-party components

Kizuna's software components—including Swift source code, tests, scripts, project configuration, and documentation—are provided under the [Apache License 2.0](LICENSE). The original Kizuna software was developed by VIUK-Light. See [NOTICE](NOTICE) for the attribution that must accompany redistributions.

The license boundaries and assets that require replacement before redistribution are summarized in [LICENSES.md](LICENSES.md).

The following content is not licensed under the Apache License 2.0. Unless separately and explicitly licensed, all rights to this content are reserved by VIUK-Light contributors.

- `KizunaAI/Assets.xcassets/**`
- `GeneratedStories/**`
- `docs/screenshots/**`
- `KizunaAI/AI/CharacterLibrary/SeedData/SeedStoryPacks*.json`
- Creative content, including character definitions, stories, dialogue, and scenarios
- The Kizuna and VIUK-Light names, logos, and brand assets

Third-party code and components remain subject to their respective licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `Licenses/`.
