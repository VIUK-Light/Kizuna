# Web access and client-independent boundary

Status: accepted design direction (implementation not started)

Tracks: [#438](https://github.com/VIUK-Light/Kizuna/issues/438)

Last updated: 2026-08-21

## Decision

Kizuna will keep the native iOS and macOS clients. The first route for
Windows, Linux, ChromeOS, and installation-restricted computers will be a Web
client, not a Windows-native wrapper.

The Web client will be a TypeScript/React browser application that consumes a
versioned Kizuna HTTP API. It will not call model providers directly. A
Linux-capable API service will own use-case orchestration, safety checks,
persistence, provider routing, and credentials. The existing Apple clients
will continue to call the same domain concepts in-process so local AI and
offline behavior are not forced through a hosted service.

The first OSS preview will be self-hostable and single-user. Publishing a
shared Kizuna service is a separate release gate that requires authentication,
tenant isolation, retention rules, abuse controls, and a privacy/security
review.

## Why Web first

- One browser client creates an access path for Windows, Linux, ChromeOS, and
  managed computers without adding a desktop installer or updater.
- SwiftUI remains the right presentation layer for the existing Apple apps;
  replacing it would discard working native behavior without helping the Web
  boundary.
- A transport contract lets future clients evolve independently from the
  server implementation and makes platform capabilities explicit.
- A Web-first route avoids committing to Electron or a separate Windows-native
  UI before the core/API boundary has been proven.

## Target boundary

```text
Native iOS/macOS (SwiftUI) ── in-process adapters ─┐
                                                   ├─ Kizuna use cases
Web (TypeScript/React) ── HTTPS JSON + event stream┤  and safety policy
                                                   ├─ repositories
Future clients ─────────── versioned Kizuna API ──┘
                                                      │
                                                      └─ remote AI providers
```

Sharing a contract is required; sharing every implementation language is not.
Where it is practical, Foundation-only models, prompt construction, safety
policy, and use cases should move into a Swift package tentatively named
`KizunaCore`. The Web client consumes OpenAPI-derived TypeScript types rather
than importing Swift or re-declaring wire formats by hand.

### Current code and extraction work

| Area | Current reusable seam | Required separation |
| --- | --- | --- |
| Character domain | `CharacterProfile`, lore, memory models and `CharacterRepository` | Move domain validation and use cases out of SwiftUI view models; keep local JSON as one repository adapter. |
| Story domain | `StoryWorld`, `StoryScene`, `StorySession` and Story repository protocols | Remove UI/logging/singleton assumptions from orchestration and expose revision/idempotency errors through the API. |
| Persona domain | `PersonaProfile`, `PersonaThread`, prompt builder and per-thread persistence | Define a repository/use-case protocol independent of `ObservableObject`, `UserDefaults`, and `@MainActor`. |
| AI routing | `AIGenerationRequest`, `AIGenerationResponse`, `AIProvider`, and `AIModelRouter` | Replace MainActor callbacks with a transport-neutral async event stream; inject registry and credential access. |
| Safety | Character/input/output safety protocols and policy types | Keep safety evaluation server-authoritative for Web turns and publish stable reason/action codes. |
| Apple adapters | SwiftUI, Keychain, Application Support, local model manager/runtime | Remain native-only implementations behind capability and repository/provider boundaries. |

`KizunaCore` must not import SwiftUI, AppKit, UIKit, Security/Keychain APIs, or
the local llama.cpp/LiteRT-LM bridge. Platform adapters may import the core,
never the reverse.

## API v1 shape

The contract will be checked into `contracts/kizuna-api-v1.yaml` before Web UI
work starts. Initial transport rules are:

- HTTPS with JSON request/response bodies.
- UUIDs encoded as lowercase strings and timestamps as UTC ISO-8601 strings.
- `/v1/capabilities` reports supported features and provider roles; clients do
  not infer support from the platform name.
- Generation uses a `POST` request with a client-generated idempotency key and
  a fetch-compatible server event stream. Events have stable types such as
  `accepted`, `progress`, `text_delta`, `completed`, and `failed`.
- A generation resource has an explicit cancellation endpoint. Retrying the
  same idempotency key must not append a second assistant turn.
- Mutation responses carry a revision/ETag. Stale edits fail with a conflict
  instead of overwriting a newer turn.
- Errors expose a stable code and correlation ID; logs and responses must not
  echo credentials or full private prompts.

The first contract covers these resources:

| Resource | Minimum operations |
| --- | --- |
| Capabilities | Read platform, model-role, import/export, and streaming support. |
| Characters | List, read, create, update, delete, and manage the lorebook. |
| Persona threads | List summaries, page messages, create/rename/delete, submit/cancel/retry a turn. |
| Story worlds/sessions | List/read worlds, list/create sessions, page messages, submit/cancel/retry a turn. |
| Portable data | Export a versioned document, validate an import, then explicitly commit it. |

Conversation list responses must contain summaries only. Message bodies are
paged by an opaque cursor so Web startup does not download every conversation.

## Remote-provider behavior

Web capability profiles set `localRuntime` to unavailable. Persona and Story
generation route through enabled remote-provider configurations on the API
service. The existing rule against silently crossing an explicitly selected
provider/model family remains in force.

Provider credentials must never be returned to, logged by, or stored in
browser storage. A self-hosted preview reads operator-managed secrets from its
server environment or server credential store. A future shared service needs
an encrypted, account-scoped server credential store before BYOK can be
enabled. Browser-to-provider calls and API keys in LocalStorage/IndexedDB are
out of scope.

Safety input/output checks and response sanitization run inside the API service
for every generated turn. A Web client may add presentation safeguards, but it
cannot bypass the server decision.

## Web MVP

The first user-testable Web milestone includes:

1. Character Library list, create, edit, delete, avatar upload, and lorebook.
2. Persona thread list, paged history, streaming remote generation,
   cancellation, retry, rename, and delete.
3. Story world/session list, Story chat continuation, streaming remote
   generation, cancellation, and retry. Advanced world editing may follow the
   first chat slice.
4. Capability-driven remote model selection. Local AI controls stay hidden
   when unsupported.
5. Versioned export plus validate-then-import. Automatic account sync is not
   required for the MVP.
6. A clear delete-all-data action and a non-persistent guest mode before the
   client is promoted for use on shared computers.

The MVP does not include a Windows-native app, direct browser local-model
execution, automatic Apple/Web synchronization, native Keychain access,
background native integrations, or every advanced model setting.

## Storage and hosting gates

The self-hosted preview uses API-owned durable repositories with a single-user
scope. Browser caches may hold replaceable UI data but not the authoritative
conversation history or provider secrets.

A public hosted deployment is blocked until all of the following exist:

- authenticated sessions and server-side authorization on every object;
- tenant-scoped repository tests, CSRF/CORS protections, and rate limits;
- documented retention, export, deletion, backup, and incident procedures;
- secret redaction and security logging that excludes conversation bodies;
- a threat-model and privacy review, including shared-computer sign-out and
  guest-data cleanup behavior.

## Delivery sequence

1. **Contract fixtures:** add OpenAPI v1, JSON fixtures, compatibility tests,
   capabilities, error codes, paging, streaming, and idempotency semantics.
2. **Core extraction:** move one vertical slice (Character list plus Persona
   turn) behind injected repository, provider, clock, ID, and safety protocols.
   Keep the Apple behavior unchanged through native adapters.
3. **Self-hosted API:** implement the vertical slice with remote-provider-only
   capabilities and durable single-user storage.
4. **Web vertical slice:** build Character Library and Persona Chat in the
   TypeScript/React client; verify Windows browser keyboard, screen-reader,
   responsive, streaming cancellation, import/export, and recovery flows.
5. **Story slice:** add Story continuation using the same turn/revision/event
   contracts rather than a second feature-specific transport.
6. **Hosted-service gate:** decide operator, authentication, data location,
   retention, abuse handling, and public URL only after the security/privacy
   gates above pass.

Each phase must be independently reviewable. A Web UI PR must not begin by
copying SwiftUI state machines into TypeScript or by exposing provider secrets
to make a demo work.

## Issue #438 completion mapping

- [x] Windows access route: Web-first; no Windows-native client in the first phase.
- [x] Web realization: TypeScript/React client over a versioned HTTP/event-stream API.
- [x] Apple/domain/AI boundaries: inventory and extraction rules above.
- [x] Minimum Web features: Character, Persona, Story, remote provider, and portable data defined above.
- [x] Local-AI fallback: explicit capability says unavailable; the API routes only to configured remote providers.
- [x] README platform status and direction link: documented in both README variants.

This checklist accepts the architecture direction; it does not claim that a
Web client or hosted Kizuna service is already available.
