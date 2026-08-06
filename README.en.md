# Kizuna

[日本語](README.md) | English

**A SwiftUI app for building relationships and stories with AI characters while respecting user agency and real life.**

Kizuna is an open-source character AI application for iOS and macOS. It supports persistent conversations, relationships, and stories while aiming to preserve expressive character experiences without optimizing for dependency or isolation from real-world relationships.

<table>
  <tr>
    <td align="center">
      <img src="docs/screenshots/story-library.jpg" width="210" alt="Kizuna story library"><br>
      <strong>Story library</strong>
    </td>
    <td align="center">
      <img src="docs/screenshots/character-chat.jpg" width="210" alt="Kizuna character chat"><br>
      <strong>Character chat</strong>
    </td>
  </tr>
  <tr>
    <td align="center">
      <img src="docs/screenshots/story-history.jpg" width="210" alt="Kizuna ongoing stories"><br>
      <strong>Ongoing stories</strong>
    </td>
    <td align="center">
      <img src="docs/screenshots/character-profile.jpg" width="210" alt="Kizuna character profile"><br>
      <strong>Character profile</strong>
    </td>
  </tr>
</table>

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

Issues and Pull Requests should include, where possible:

- Reproduction steps, expected behavior, and actual behavior
- iOS / macOS, device / Simulator, OS, and Xcode versions
- Model format and whether local or remote generation was used
- Logs or screenshots with API keys and personal information removed

Do not publish conversation history, API keys, access tokens, private URLs, or other secrets.

## Licenses

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `Licenses/` for third-party component licenses.
