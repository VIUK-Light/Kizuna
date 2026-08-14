import Foundation

/// Internal-only observation of one Story model turn.
///
/// The production UI does not install a handler, so prompts and raw model
/// output never leave the normal Story pipeline. The acceptance runner uses
/// this value to hash the exact condition prompt and to record the text after
/// the existing parser has removed STATE_UPDATE metadata.
struct StoryAcceptanceGenerationTrace {
    let generationID: UUID
    let model: StoryGenerationModel
    let systemPrompt: String
    let userPrompt: String
    let rawOutput: String?
    let visibleText: String?
    let stateUpdate: StoryStatePatch?
    let backend: String
    let modelIdentity: String?
    let modelLatencyMilliseconds: Double?
    let requestedSeed: UInt32?
    let effectiveSeed: UInt32?
    let seedMode: String?
}
