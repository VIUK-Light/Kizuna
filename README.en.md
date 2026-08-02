# Kizuna

[日本語](README.md) | English

**A SwiftUI application for building relationships and stories with AI characters while respecting user agency and real life.**

Kizuna is an open-source iOS and macOS character AI application developed by VIUK-Light. It focuses on responsible AI, privacy, user control, and maintaining expressive character experiences without optimizing for dependency or excessive screen time.

## Features

- Persistent AI character relationships and stories
- Safety behavior designed to preserve character consistency
- Architecture that separates local and remote model providers
- User-controlled conversations, memories, models, and secrets
- Native SwiftUI support for iOS and macOS
- Open development with Issues and Pull Requests welcome

> Kizuna is designed neither to control users nor to push them away.

## Project status

Kizuna is under active development. Feature proposals, bug reports, documentation improvements, and Pull Requests are welcome.

Requirements currently include Xcode 26.1 or later, XcodeGen, and iOS 26.0 / macOS 26.0 or later.

## Design principles

- Safety should protect the user without unnecessarily destroying the character or story experience.
- Kizuna is not designed to make users dependent on the application or isolate them from real-world relationships.
- Users should be able to make choices instead of having the AI decide their feelings, actions, or relationships for them.
- The application should be transparent about being AI and should not pretend to have real-world capabilities it does not have.
- Local models and user-controlled settings can help reduce unnecessary data exposure.

## Technical design and implementation

Kizuna separates the SwiftUI interface, conversation services, model management, runtime integration, and secret storage. The UI does not call a specific model provider directly. Platform-specific runtime behavior is kept behind explicit boundaries so that iOS and macOS can share the product-level flow while using different native implementations.

### Startup and initialization

The application entry point is KizunaAI/App/KizunaAIApp.swift. At startup, KizunaMigrationGateView prepares the application and runtime state before presenting VIUKKizunaWorkspaceView.

    KizunaAIApp
      └─ KizunaMigrationGateView
           └─ VIUKKizunaWorkspaceView
                ├─ Character Library
                ├─ Persona Chat
                ├─ Story Session
                └─ Settings / Model Management

### Conversation pipeline

PersonaChatService.swift accepts user input, stores the user message and a placeholder assistant message, builds the prompt from persona, character, memory, and safety state, and requests generation through LocalAssistantRuntimeBridge. Streaming text is displayed while generation is running and is committed to the conversation store when the response completes.

    User input
      → PersonaChatService
      → PersonaChatStore
      → character, memory, and safety prompt construction
      → LocalAssistantRuntimeBridge
      → local or remote generation
      → streaming response
      → persisted assistant message

Character-bound threads use the Character Library repositories, memory selection, summarization, safety checks, and prompt builders. Existing persona threads keep a compatibility path for the established streaming behavior.

### Character Library and safety

AI/CharacterLibrary contains separate models and repositories for character profiles, lorebooks, memories, templates, stories, sessions, and reports. Safety is not implemented as a single universal refusal message. Changes should consider context, creative role-play, character consistency, user agency, and real-world risk.

### Local model lifecycle

LocalAssistantModelManager.swift handles model URLs, access tokens, storage, installation state, progress, and resumable downloads. The lifecycle distinguishes preflight checks, active downloads, paused or resumable transfers, failures, and completed installations.

Download state and resume data are persisted so that a network interruption does not always require downloading a multi-gigabyte model from the beginning. Changes to this area should consider Range and ETag handling, partial files, resume-data invalidation, disk-space checks, and the point at which a filename becomes final.

### Runtime boundaries

LocalAssistantRuntimeBridge.swift separates conversation code from inference implementations.

- macOS uses bundled llama-cli / llama-server executables and arm64 llama.cpp libraries.
- iOS uses iOS-compatible llama.cpp libraries and the LiteRT-LM native path.
- Saved, executable, missing, failed, and unavailable model states are kept distinct.
- Runtime failures should be surfaced as recoverable application state where possible.

project.yml is used by XcodeGen to generate KizunaAI.xcodeproj. A post-build script bundles the macOS runtime executables into the application resources and re-signs them when required. Generated build products, model caches, and DerivedData must not be committed.

### Secret storage

AISecretStore defines the purposes of API keys and model access tokens, while KeychainHelper stores them in the Keychain. Secrets must not be committed to source code, Info.plist, UserDefaults, logs, or documentation. Legacy values are migrated into the current Keychain service and removed from the old representation.

## Development

Requirements:

- macOS
- Xcode 26.1 or later
- XcodeGen
- iOS 26.0 / macOS 26.0 or later
- Apple Silicon llama.cpp libraries for macOS

Generate the project after changing project.yml:

    xcodegen generate

Unsigned macOS validation build:

    xcodebuild -project KizunaAI.xcodeproj -scheme KizunaAI -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

Unsigned iOS Simulator validation build:

    xcodebuild -project KizunaAI.xcodeproj -scheme KizunaAI -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

## Pull Requests, Issues, and problem reports

Pull requests are welcome. Contributions can include features, bug fixes, documentation, tests, design discussions, and small reproducible examples. Small fixes and investigation-only Issues are useful too.

When reporting a problem or opening a Pull Request, include as much of the following as is available:

- related Pull Request, Issue, or commit URLs
- what happened, when it started, and how often it reproduces
- reproduction steps, expected result, and actual result
- iOS or macOS, device or Simulator, OS version, and Xcode version
- model format, model size, and local or remote generation path
- download state, runtime state, and the action immediately before the failure
- logs, crash information, or screenshots with secrets removed
- the last known working commit or the first failing commit, if known

Please anonymize or summarize private conversation content before sharing it. Do not attach API keys, access tokens, cookies, private URLs, model files, or raw personal conversation history to a Pull Request or Issue.

## Third-party components

See THIRD_PARTY_NOTICES.md and the files under Licenses/ for the licenses of bundled runtimes and libraries.
