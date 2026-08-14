import CryptoKit
import Foundation
import XCTest
@testable import KizunaAI

/// Opt-in, app-path acceptance runner for the Story initiative experiment.
///
/// This test is intentionally skipped in normal CI. The runner is invoked by
/// a shell wrapper with an isolated application-data root, an explicit model
/// artifact, and an output path outside the repository. It never reads or
/// writes the user's normal Kizuna data.
@MainActor
final class StoryInitiativeAcceptanceRunnerTests: XCTestCase {
    private static let schemaVersion = 1
    private static let defaultTurnTimeout: TimeInterval = 240

    func testAcceptanceSelectionsRejectNormalizedDuplicates() {
        XCTAssertThrowsError(try parseLanguages(["ja", "ja"]))
        XCTAssertThrowsError(try parseModels(["iori", "e4b"]))
        XCTAssertThrowsError(
            try parseScenarioIDs(["story-01", "story-01"], defaults: ["story-01", "story-02"])
        )
        XCTAssertThrowsError(try parseSeeds(["1", "01"]))
    }

    func testGenerationMetadataEncodingExcludesRawEvaluationContent() throws {
        let record = StoryAcceptanceGenerationRecord(
            schemaVersion: Self.schemaVersion,
            recordType: "generation",
            pairID: "ja-iori-story-01-1",
            language: "ja",
            model: "iori",
            scenarioID: "story-01",
            scenarioVersion: "story-initiative-fixture-v2",
            fixtureSHA256: String(repeating: "a", count: 64),
            promptSHA256: String(repeating: "b", count: 64),
            pairInputSHA256: String(repeating: "c", count: 64),
            seed: StoryAcceptanceSeedRecord(requested: 1, effective: 1, mode: "sampler"),
            condition: "baseline",
            status: "completed",
            canary: StoryAcceptanceCanaryRecord(
                initiativeEnabled: false,
                activationSource: "none"
            ),
            latency: StoryAcceptanceLatencyRecord(model: 1, turnEndToEnd: 2),
            runtime: StoryAcceptanceRuntimeRecord(
                provider: "local-story-runtime",
                backend: "test-runtime",
                modelIdentity: "test-model.gguf",
                modelIdentityObserved: true,
                modelSHA256: String(repeating: "d", count: 64),
                promptObserved: true,
                effectiveSeed: 1,
                seedMode: "sampler",
                failureCode: nil
            )
        )

        let data = try Self.makeJSONEncoder().encode(record)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNil(object["response_text"])
        XCTAssertNil(object["context"])
        XCTAssertNil(object["state_update"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("user message"))
    }

    func testStoryInitiativeAcceptanceMatrix() async throws {
        guard ProcessInfo.processInfo.environment["KIZUNA_RUN_STORY_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Set KIZUNA_RUN_STORY_ACCEPTANCE=1 to run the real app-path matrix.")
        }

        let fixtureURL = fixtureURL()
        let fixtureData = try Data(contentsOf: fixtureURL)
        let fixtureObject = try JSONSerialization.jsonObject(with: fixtureData)
        guard let fixture = try? JSONDecoder().decode(StoryAcceptanceFixture.self, from: fixtureData) else {
            XCTFail("The Story initiative fixture could not be decoded.")
            return
        }
        guard fixture.schemaVersion == Self.schemaVersion,
              fixture.scenarios.count == 16 else {
            XCTFail("The acceptance fixture must be schema 1 with exactly 16 scenarios.")
            return
        }

        let fixtureSHA256 = try Self.sha256CanonicalJSONObject(fixtureObject)
        let languages = try selectedLanguages()
        let models = try selectedModels()
        let scenarioIDs = try selectedScenarioIDs(from: fixture)
        let seeds = try selectedSeeds()
        let turnTimeout = selectedTurnTimeout()

        let projectRootURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["SRCROOT"]
                ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let outputURL = try resolvedExternalOutputURL(
            environmentKey: "KIZUNA_ACCEPTANCE_OUTPUT",
            projectRootURL: projectRootURL
        )
        let ratingOutputURL = try resolvedExternalOutputURL(
            environmentKey: "KIZUNA_ACCEPTANCE_RATING_OUTPUT",
            projectRootURL: projectRootURL
        )
        try initializeJSONLOutput(at: outputURL)
        try initializeJSONLOutput(at: ratingOutputURL)

        let previousLanguage = UserDefaults.standard.string(forKey: "kizuna.language")
        let previousInitiativeFlags: [String: Any?] = [
            StoryInitiativeFlags.ioriUserDefaultsKey: UserDefaults.standard.object(
                forKey: StoryInitiativeFlags.ioriUserDefaultsKey
            ),
            StoryInitiativeFlags.nagiUserDefaultsKey: UserDefaults.standard.object(
                forKey: StoryInitiativeFlags.nagiUserDefaultsKey
            )
        ]
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: "kizuna.language")
            } else {
                UserDefaults.standard.removeObject(forKey: "kizuna.language")
            }
            for (key, value) in previousInitiativeFlags {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        for language in languages {
            UserDefaults.standard.set(language.rawValue, forKey: "kizuna.language")
            for model in models {
                for scenarioID in scenarioIDs {
                    guard let scenario = fixture.scenarios.first(where: { $0.scenarioID == scenarioID }) else {
                        XCTFail("Missing scenario \(scenarioID).")
                        continue
                    }
                    let localized = scenario.localized(for: language)
                    let entities = makeEntities(
                        scenario: scenario,
                        localized: localized,
                        language: language,
                        model: model
                    )
                    for seed in seeds {
                        let pairInputSHA256 = try Self.pairInputSHA256(
                            language: language,
                            model: model,
                            scenario: scenario,
                            localized: localized,
                            seed: seed
                        )

                        for condition in StoryAcceptanceCondition.allCases {
                            let artifacts = try await runTurn(
                                language: language,
                                model: model,
                                scenario: scenario,
                                localized: localized,
                                entities: entities,
                                condition: condition,
                                seed: seed,
                                pairInputSHA256: pairInputSHA256,
                                fixtureSHA256: fixtureSHA256,
                                turnTimeout: turnTimeout
                            )
                            try appendJSONL(artifacts.generation, to: outputURL)
                            try appendJSONL(artifacts.ratingInput, to: ratingOutputURL)
                        }
                    }
                }
            }
        }

    }

    private func runTurn(
        language: KizunaLanguage,
        model: StoryGenerationModel,
        scenario: StoryAcceptanceScenario,
        localized: StoryAcceptanceLocalizedScenario,
        entities: StoryAcceptanceEntities,
        condition: StoryAcceptanceCondition,
        seed: UInt32,
        pairInputSHA256: String,
        fixtureSHA256: String,
        turnTimeout: TimeInterval
    ) async throws -> StoryAcceptanceTurnArtifacts {
        try Task.checkCancellation()
        let startedAt = Date()
        let pairID = "\(language.rawValue)-\(model.acceptanceName)-\(scenario.scenarioID)-\(seed)"
        let expectedInitiative = condition == .initiative
        StoryInitiativeFlags.setEnabled(expectedInitiative, for: model)
        let actualInitiative = StoryInitiativeFlags.isEnabled(for: model)
        let activationSource = expectedInitiative && actualInitiative ? "userdefaults" : "none"
        let entitiesForTurn = entities.withSession(condition: condition, seed: seed)
        let traceBox = StoryAcceptanceTraceBox()

        var service: StorySessionService?
        var sentUserMessageID: UUID?
        var persistedSession: StorySession?
        var status = StoryAcceptanceStatus.error
        var responseText = ""
        var failureCode: String?
        var trace: StoryAcceptanceGenerationTrace?
        var modelLatencyMilliseconds: Double = 0

        do {
            // saveSession advances the persisted revision. Re-read the
            // session before handing it to the app path so beginTurn receives
            // the same revision that is on disk instead of a stale fixture
            // snapshot (nil/0 versus persisted 1).
            let persistedFixtureSession = try await saveFixture(entities: entitiesForTurn)
            let createdService = StorySessionService()
            service = createdService
            createdService.acceptanceGenerationTraceHandler = { trace in
                traceBox.value = trace
            }

            sentUserMessageID = createdService.send(
                localized.userMessage,
                session: persistedFixtureSession,
                world: entitiesForTurn.world,
                scene: entitiesForTurn.scene,
                generationModel: model,
                seedOverride: seed
            )

            guard sentUserMessageID != nil else {
                failureCode = "send_rejected"
                status = .error
                let runtimeObservation = runtimeRecord(
                    model: model,
                    trace: nil,
                    service: createdService,
                    failureCode: failureCode
                )
                return makeArtifacts(
                    pairID: pairID,
                    language: language,
                    model: model,
                    scenario: scenario,
                    localized: localized,
                    condition: condition,
                    seed: seed,
                    fixtureSHA256: fixtureSHA256,
                    pairInputSHA256: pairInputSHA256,
                    actualInitiative: actualInitiative,
                    activationSource: activationSource,
                    status: status,
                    responseText: responseText,
                    startedAt: startedAt,
                    modelLatencyMilliseconds: 0,
                    promptSHA256: runtimeObservation.promptSHA256,
                    runtime: runtimeObservation.record
                )
            }

            let deadline = Date().addingTimeInterval(turnTimeout)
            while createdService.phase == .thinking && Date() < deadline {
                try await Task.sleep(nanoseconds: 250_000_000)
            }

            if createdService.phase == .thinking {
                failureCode = "runner_timeout"
                createdService.cancel()
                status = .timeout
                for _ in 0..<20 where createdService.phase == .thinking {
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            }

            let sessionRepository = LocalJSONStorySessionRepository()
            persistedSession = try? await sessionRepository
                .fetchSessions(storyWorldId: entitiesForTurn.world.id)
                .first(where: { $0.id == entitiesForTurn.session.id })
            trace = traceBox.value
            modelLatencyMilliseconds = trace?.modelLatencyMilliseconds ?? 0

            let checkpoint = persistedSession?.latestTurnCheckpoint
            let turnID = checkpoint?.turnID
            let turnMessages = persistedSession?.messages.filter { message in
                guard let turnID, message.turnID == turnID else { return false }
                if case .user = message.author { return false }
                if case .system = message.author { return false }
                return true
            } ?? []
            responseText = turnMessages.map(\.text).joined(separator: "\n")
            let committed = checkpoint?.status == .committed && !turnMessages.isEmpty

            if status == .timeout {
                // Preserve the timeout even if a late callback finishes while
                // the runner is cleaning up. The record must expose that the
                // operation exceeded the runner's bounded wait.
                failureCode = failureCode ?? "runner_timeout"
            } else if let trace,
                      trace.modelIdentity != nil,
                      committed,
                      !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = .completed
                failureCode = nil
            } else if let trace,
                      committed,
                      !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      trace.modelIdentity == nil {
                // A persisted runtime notice is not a model generation. Do
                // not let an API-key error or local-runtime failure become a
                // completed blind-evaluation sample.
                status = .error
                failureCode = "model_identity_not_observed"
            } else if createdService.acceptanceInputSafetyBlocked {
                status = .blocked
                failureCode = checkpoint?.failureCode ?? createdService.latestRuntimeNotice?.backendName
            } else if let checkpoint, checkpoint.status != .committed {
                status = .error
                failureCode = checkpoint.failureCode
                    ?? createdService.latestRuntimeNotice?.backendName
                    ?? "turn_not_committed"
            } else if checkpoint == nil {
                // A send can return before the runtime discovers that the
                // turn cannot begin. Without a checkpoint there is no
                // committed or intentionally empty model response; classify
                // it as an operational app-path error.
                status = .error
                failureCode = createdService.latestRuntimeNotice?.backendName
                    ?? "turn_checkpoint_missing"
            } else if responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                status = .empty
                failureCode = createdService.latestRuntimeNotice?.backendName ?? "empty_response"
            } else {
                status = .error
                failureCode = "trace_or_commit_missing"
            }
        } catch is CancellationError {
            service?.cancel()
            throw CancellationError()
        } catch {
            status = .error
            failureCode = "runner_setup_or_persistence_error"
        }

        let runtimeObservation = runtimeRecord(
            model: model,
            trace: trace,
            service: service,
            failureCode: failureCode
        )
        return makeArtifacts(
            pairID: pairID,
            language: language,
            model: model,
            scenario: scenario,
            localized: localized,
            condition: condition,
            seed: seed,
            fixtureSHA256: fixtureSHA256,
            pairInputSHA256: pairInputSHA256,
            actualInitiative: actualInitiative,
            activationSource: activationSource,
            status: status,
            responseText: status == .completed ? responseText : "",
            startedAt: startedAt,
            modelLatencyMilliseconds: modelLatencyMilliseconds,
            promptSHA256: runtimeObservation.promptSHA256,
            runtime: runtimeObservation.record
        )
    }

    private func saveFixture(entities: StoryAcceptanceEntities) async throws -> StorySession {
        let characterRepository = LocalJSONCharacterRepository()
        let worldRepository = LocalJSONStoryWorldRepository()
        let castRepository = LocalJSONCastRepository()
        let sceneRepository = LocalJSONStorySceneRepository()
        let sessionRepository = LocalJSONStorySessionRepository()

        try await characterRepository.saveCharacter(entities.character)
        try await worldRepository.saveWorld(entities.world)
        try await castRepository.saveCast(entities.cast)
        try await sceneRepository.saveScene(entities.scene)
        try await sessionRepository.saveSession(entities.session)
        guard let persistedSession = try await sessionRepository
            .fetchSessions(storyWorldId: entities.world.id)
            .first(where: { $0.id == entities.session.id }) else {
            throw StoryAcceptanceRunnerError.sessionNotPersisted
        }
        return persistedSession
    }

    private func makeArtifacts(
        pairID: String,
        language: KizunaLanguage,
        model: StoryGenerationModel,
        scenario: StoryAcceptanceScenario,
        localized: StoryAcceptanceLocalizedScenario,
        condition: StoryAcceptanceCondition,
        seed: UInt32,
        fixtureSHA256: String,
        pairInputSHA256: String,
        actualInitiative: Bool,
        activationSource: String,
        status: StoryAcceptanceStatus,
        responseText: String,
        startedAt: Date,
        modelLatencyMilliseconds: Double,
        promptSHA256: String,
        runtime: StoryAcceptanceRuntimeRecord
    ) -> StoryAcceptanceTurnArtifacts {
        let effectiveSeed = Int(runtime.effectiveSeed ?? seed)
        let seedMode = runtime.seedMode ?? "draw"
        let latency = StoryAcceptanceLatencyRecord(
            model: max(0, modelLatencyMilliseconds),
            turnEndToEnd: max(0, Date().timeIntervalSince(startedAt) * 1_000)
        )
        let generation = StoryAcceptanceGenerationRecord(
            schemaVersion: Self.schemaVersion,
            recordType: "generation",
            pairID: pairID,
            language: language.rawValue,
            model: model.acceptanceName,
            scenarioID: scenario.scenarioID,
            scenarioVersion: scenario.scenarioVersion,
            fixtureSHA256: fixtureSHA256,
            promptSHA256: promptSHA256,
            pairInputSHA256: pairInputSHA256,
            seed: StoryAcceptanceSeedRecord(
                requested: Int(seed),
                effective: effectiveSeed,
                mode: seedMode
            ),
            condition: condition.rawValue,
            status: status.rawValue,
            canary: StoryAcceptanceCanaryRecord(
                initiativeEnabled: actualInitiative,
                activationSource: activationSource
            ),
            latency: latency,
            runtime: runtime
        )
        let ratingInput = StoryAcceptanceRatingInput(
            schemaVersion: Self.schemaVersion,
            recordType: "rating_input",
            pairID: pairID,
            condition: condition.rawValue,
            status: status.rawValue,
            context: StoryAcceptanceContext(localized: localized),
            responseText: responseText
        )
        return StoryAcceptanceTurnArtifacts(
            generation: generation,
            ratingInput: ratingInput
        )
    }

    private func runtimeRecord(
        model: StoryGenerationModel,
        trace: StoryAcceptanceGenerationTrace?,
        service: StorySessionService?,
        failureCode: String?
    ) -> StoryAcceptanceRuntimeObservation {
        let environment = ProcessInfo.processInfo.environment
        let modelIdentity: String
        let modelIdentityObserved: Bool
        let provider: String
        if let trace {
            modelIdentity = Self.sanitizedModelIdentity(trace.modelIdentity)
                ?? "unobserved-runtime"
            modelIdentityObserved = trace.modelIdentity != nil
            provider = model == .b31 ? "google-generative-language-api" : "local-story-runtime"
        } else if model == .e4b {
            modelIdentity = "unobserved-local-runtime"
            modelIdentityObserved = false
            provider = "local-story-runtime"
        } else {
            modelIdentity = "gemma-4-31b-it|fallback:gemma-4-26b-a4b-it"
            modelIdentityObserved = false
            provider = "google-generative-language-api"
        }
        let promptSHA256 = trace.map {
            Self.sha256(Data("\($0.systemPrompt)\n---user---\n\($0.userPrompt)".utf8))
        } ?? Self.sha256(Data("kizuna-no-model-prompt".utf8))
        return StoryAcceptanceRuntimeObservation(
            record: StoryAcceptanceRuntimeRecord(
                provider: provider,
                backend: trace?.backend ?? service?.latestRuntimeNotice?.backendName ?? "not-observed",
                modelIdentity: modelIdentity,
                modelIdentityObserved: modelIdentityObserved,
                modelSHA256: environment["KIZUNA_IORI_MODEL_SHA256"],
                promptObserved: trace != nil,
                effectiveSeed: trace?.effectiveSeed,
                seedMode: trace?.seedMode,
                failureCode: failureCode
            ),
            promptSHA256: promptSHA256
        )
    }

    private static func sanitizedModelIdentity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fileName = URL(fileURLWithPath: trimmed).lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else { return nil }
        return fileName
    }

    private func makeEntities(
        scenario: StoryAcceptanceScenario,
        localized: StoryAcceptanceLocalizedScenario,
        language: KizunaLanguage,
        model: StoryGenerationModel
    ) -> StoryAcceptanceEntities {
        let base = "\(language.rawValue)-\(model.acceptanceName)-\(scenario.scenarioID)"
        let worldID = Self.stableUUID(for: base + ":world")
        let characterID = Self.stableUUID(for: base + ":character")
        let sceneID = Self.stableUUID(for: base + ":scene")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let worldSetting = [
            localized.scene.location,
            localized.scene.timeOfDay,
            localized.scene.mood,
            localized.scene.conflict,
            localized.hardFacts.joined(separator: " / ")
        ].joined(separator: "\n")
        let world = StoryWorld(
            id: worldID,
            title: "Story initiative \(scenario.scenarioID)",
            shortDescription: localized.scene.mood,
            genre: .originalFreeform,
            relationshipGenre: .none,
            // Oracle labels are evaluator-only metadata. Never put them in a
            // World, Character, prompt, or any other app-path input.
            tags: ["acceptance"],
            worldSetting: worldSetting,
            userRole: language == .english ? "traveler" : "同行者",
            openingScene: localized.userMessage,
            storyGoal: localized.storyState.activeGoal,
            mood: localized.scene.mood,
            characterIds: [characterID],
            mainCharacterId: characterID,
            castMode: .solo,
            isSystemProtected: false,
            safetyRules: [],
            visibility: .private,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let character = CharacterProfile(
            id: characterID,
            name: localized.character.name,
            displayName: localized.character.name,
            shortDescription: localized.character.relationship,
            category: .chatBuddy,
            relationshipGenre: .none,
            personality: localized.character.purpose,
            speakingStyle: language == .english ? "brief and natural" : "短く自然な口調",
            background: localized.character.relationship,
            relationshipToUser: localized.character.relationship,
            scenario: localized.userMessage,
            firstMessage: "",
            tags: ["acceptance"],
            rules: [],
            safetyRules: [],
            visibility: .private,
            safetyRating: .general,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let cast = CastMember(
            storyWorldId: worldID,
            characterId: characterID,
            roleInStory: .main,
            importance: 1,
            introductionTiming: .opening,
            relationshipToUser: localized.character.relationship,
            isUserControlled: false,
            isActiveInCurrentScene: true
        )
        let scene = StoryScene(
            id: sceneID,
            storyWorldId: worldID,
            title: localized.scene.location,
            location: localized.scene.location,
            timeOfDay: localized.scene.timeOfDay,
            mood: localized.scene.mood,
            activeCharacterIds: [characterID],
            sceneGoal: localized.storyState.activeGoal,
            conflict: localized.scene.conflict,
            summary: localized.scene.location,
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        let historyMessages = localized.history.enumerated().map { index, text in
            StoryMessage(
                id: Self.stableUUID(for: base + ":history:\(index)"),
                author: .narrator,
                text: text,
                createdAt: fixedDate
            )
        }
        return StoryAcceptanceEntities(
            world: world,
            character: character,
            cast: cast,
            scene: scene,
            relationshipStage: localized.storyState.relationshipStage,
            session: StorySession(
                storyWorldId: worldID,
                messages: historyMessages
            )
        )
    }

    private func fixtureURL() -> URL {
        if let path = ProcessInfo.processInfo.environment["KIZUNA_ACCEPTANCE_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        let root = ProcessInfo.processInfo.environment["SRCROOT"]
            ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: root)
            .appendingPathComponent("tools/story_initiative_scenarios.json")
    }

    private func selectedLanguages() throws -> [KizunaLanguage] {
        let values = selectionValues(key: "KIZUNA_ACCEPTANCE_LANGUAGES", defaults: ["ja", "en"])
        return try parseLanguages(values)
    }

    private func parseLanguages(_ values: [String]) throws -> [KizunaLanguage] {
        let languages = values.compactMap(KizunaLanguage.init(rawValue:))
        guard languages.count == values.count,
              !languages.isEmpty,
              Set(languages.map(\.rawValue)).count == languages.count else {
            throw StoryAcceptanceRunnerError.invalidSelection("languages")
        }
        return languages
    }

    private func selectedModels() throws -> [StoryGenerationModel] {
        let values = selectionValues(key: "KIZUNA_ACCEPTANCE_MODELS", defaults: ["iori", "nagi"])
        return try parseModels(values)
    }

    private func parseModels(_ values: [String]) throws -> [StoryGenerationModel] {
        let models = values.compactMap { value -> StoryGenerationModel? in
            switch value.lowercased() {
            case "iori", "e4b": return .e4b
            case "nagi", "b31": return .b31
            default: return nil
            }
        }
        guard models.count == values.count,
              !models.isEmpty,
              Set(models.map(\.acceptanceName)).count == models.count else {
            throw StoryAcceptanceRunnerError.invalidSelection("models")
        }
        return models
    }

    private func selectedScenarioIDs(from fixture: StoryAcceptanceFixture) throws -> [String] {
        let defaults = fixture.scenarios.map(\.scenarioID)
        let values = selectionValues(key: "KIZUNA_ACCEPTANCE_SCENARIOS", defaults: defaults)
        return try parseScenarioIDs(values, defaults: defaults)
    }

    private func parseScenarioIDs(_ values: [String], defaults: [String]) throws -> [String] {
        guard !values.isEmpty,
              Set(values).count == values.count,
              Set(values).isSubset(of: Set(defaults)) else {
            throw StoryAcceptanceRunnerError.invalidSelection("scenarios")
        }
        return values
    }

    private func selectedSeeds() throws -> [UInt32] {
        let values = selectionValues(key: "KIZUNA_ACCEPTANCE_SEEDS", defaults: ["1", "2", "3"])
        return try parseSeeds(values)
    }

    private func parseSeeds(_ values: [String]) throws -> [UInt32] {
        let seeds = values.compactMap { value -> UInt32? in
            guard let raw = UInt64(value), raw <= UInt64(UInt32.max) else { return nil }
            return UInt32(raw)
        }
        guard seeds.count == values.count,
              !seeds.isEmpty,
              Set(seeds).count == seeds.count else {
            throw StoryAcceptanceRunnerError.invalidSelection("seeds")
        }
        return seeds
    }

    private func selectedTurnTimeout() -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment["KIZUNA_ACCEPTANCE_TURN_TIMEOUT_SECONDS"],
              let value = TimeInterval(raw), value > 0 else {
            return Self.defaultTurnTimeout
        }
        return value
    }

    private func selectionValues(key: String, defaults: [String]) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return defaults }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func resolvedExternalOutputURL(
        environmentKey: String,
        projectRootURL: URL
    ) throws -> URL {
        guard let outputPath = ProcessInfo.processInfo.environment[environmentKey],
              !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StoryAcceptanceRunnerError.invalidOutputPath(
                "\(environmentKey) must point outside the repository."
            )
        }
        let requestedOutputURL = URL(fileURLWithPath: outputPath).standardizedFileURL
        let outputFileName = requestedOutputURL.lastPathComponent
        guard !outputFileName.isEmpty else {
            throw StoryAcceptanceRunnerError.invalidOutputPath(
                "\(environmentKey) must name a JSONL file."
            )
        }
        let resolvedOutputParentURL = requestedOutputURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let outputURL = resolvedOutputParentURL
            .appendingPathComponent(outputFileName, isDirectory: false)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let projectPathPrefix = projectRootURL.path.hasSuffix("/")
            ? projectRootURL.path
            : projectRootURL.path + "/"
        guard outputURL.path != projectRootURL.path,
              !outputURL.path.hasPrefix(projectPathPrefix) else {
            throw StoryAcceptanceRunnerError.invalidOutputPath(
                "\(environmentKey) must remain outside the repository."
            )
        }
        return outputURL
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private func initializeJSONLOutput(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func appendJSONL<Record: Encodable>(
        _ record: Record,
        to url: URL
    ) throws {
        let data = try Self.makeJSONEncoder().encode(record)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256CanonicalJSONObject(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return sha256(data)
    }

    private static func pairInputSHA256(
        language: KizunaLanguage,
        model: StoryGenerationModel,
        scenario: StoryAcceptanceScenario,
        localized: StoryAcceptanceLocalizedScenario,
        seed: UInt32
    ) throws -> String {
        let contextData = try JSONEncoder().encode(StoryAcceptanceContext(localized: localized))
        let contextObject = try JSONSerialization.jsonObject(with: contextData)
        let object: [String: Any] = [
            "context": contextObject,
            "language": language.rawValue,
            "model": model.acceptanceName,
            "scenario_id": scenario.scenarioID,
            "scenario_version": scenario.scenarioVersion,
            "seed": Int(seed)
        ]
        return try sha256CanonicalJSONObject(object)
    }

    nonisolated fileprivate static func stableUUID(for value: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(value.utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = uuid_t(
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }
}

private enum StoryAcceptanceRunnerError: Error {
    case invalidSelection(String)
    case invalidOutputPath(String)
    case sessionNotPersisted
}

private final class StoryAcceptanceTraceBox {
    var value: StoryAcceptanceGenerationTrace?
}

private enum StoryAcceptanceCondition: String, CaseIterable {
    case baseline
    case initiative
}

private enum StoryAcceptanceStatus: String {
    case completed
    case timeout
    case error
    case empty
    case blocked
    case cancelled
}

private struct StoryAcceptanceFixture: Decodable {
    let schemaVersion: Int
    let fixtureVersion: String
    let scenarios: [StoryAcceptanceScenario]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case fixtureVersion = "fixture_version"
        case scenarios
    }
}

private struct StoryAcceptanceScenario: Decodable {
    let scenarioID: String
    let scenarioVersion: String
    let ja: StoryAcceptanceLocalizedScenario
    let en: StoryAcceptanceLocalizedScenario
    let oracle: StoryAcceptanceOracle

    private enum CodingKeys: String, CodingKey {
        case scenarioID = "scenario_id"
        case scenarioVersion = "scenario_version"
        case ja
        case en
        case oracle
    }

    func localized(for language: KizunaLanguage) -> StoryAcceptanceLocalizedScenario {
        language == .english ? en : ja
    }
}

private struct StoryAcceptanceLocalizedScenario: Decodable {
    let userMessage: String
    let scene: StoryAcceptanceScene
    let storyState: StoryAcceptanceStoryState
    let character: StoryAcceptanceCharacter
    let history: [String]
    let hardFacts: [String]

    private enum CodingKeys: String, CodingKey {
        case userMessage = "user_message"
        case scene
        case storyState = "story_state"
        case character
        case history
        case hardFacts = "hard_facts"
    }
}

private struct StoryAcceptanceScene: Decodable {
    let location: String
    let timeOfDay: String
    let mood: String
    let conflict: String

    private enum CodingKeys: String, CodingKey {
        case location
        case timeOfDay = "time_of_day"
        case mood
        case conflict
    }
}

private struct StoryAcceptanceStoryState: Decodable {
    let activeGoal: String
    let relationshipStage: String
    let activeCharacter: String

    private enum CodingKeys: String, CodingKey {
        case activeGoal = "active_goal"
        case relationshipStage = "relationship_stage"
        case activeCharacter = "active_character"
    }
}

private struct StoryAcceptanceCharacter: Decodable {
    let name: String
    let purpose: String
    let relationship: String
}

private struct StoryAcceptanceOracle: Decodable {
    let initiative: String
    let allowedChangeGroups: [String]
    let safetyClass: String

    private enum CodingKeys: String, CodingKey {
        case initiative
        case allowedChangeGroups = "allowed_change_groups"
        case safetyClass = "safety_class"
    }
}

private struct StoryAcceptanceEntities {
    let world: StoryWorld
    let character: CharacterProfile
    let cast: CastMember
    let scene: StoryScene
    let relationshipStage: String
    let session: StorySession

    func withSession(
        condition: StoryAcceptanceCondition,
        seed: UInt32
    ) -> StoryAcceptanceEntities {
        let sessionID = StoryInitiativeAcceptanceRunnerTests.stableUUID(
            for: "\(world.id.uuidString):\(condition.rawValue):seed:\(seed):session"
        )
        let messages = session.messages.map { $0 }
        var next = StorySession(
            id: sessionID,
            storyWorldId: world.id,
            currentSceneId: scene.id,
            activeCharacterIds: [character.id],
            messages: messages,
            currentObjective: world.storyGoal,
            relationshipStage: nil,
            lastSceneSummary: scene.summary,
            storyState: StoryState(
                location: scene.location,
                timeOfDay: scene.timeOfDay,
                mood: scene.mood,
                relationshipStage: relationshipStage,
                characterStates: [
                    StoryCharacterState(
                        characterId: character.id,
                        characterName: character.visibleName,
                        relationship: character.relationshipToUser
                    )
                ],
                activeGoals: [world.storyGoal]
            )
        )
        next.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        next.updatedAt = next.createdAt
        return StoryAcceptanceEntities(
            world: world,
            character: character,
            cast: cast,
            scene: scene,
            relationshipStage: relationshipStage,
            session: next
        )
    }
}

private struct StoryAcceptanceContext: Encodable {
    let userMessage: String
    let scene: StoryAcceptanceSceneOutput
    let storyState: StoryAcceptanceStoryStateOutput
    let character: StoryAcceptanceCharacterOutput
    let history: [String]
    let hardFacts: [String]

    init(localized: StoryAcceptanceLocalizedScenario) {
        userMessage = localized.userMessage
        scene = StoryAcceptanceSceneOutput(scene: localized.scene)
        storyState = StoryAcceptanceStoryStateOutput(state: localized.storyState)
        character = StoryAcceptanceCharacterOutput(character: localized.character)
        history = localized.history
        hardFacts = localized.hardFacts
    }

    private enum CodingKeys: String, CodingKey {
        case userMessage = "user_message"
        case scene
        case storyState = "story_state"
        case character
        case history
        case hardFacts = "hard_facts"
    }
}

private struct StoryAcceptanceSceneOutput: Encodable {
    let location: String
    let timeOfDay: String
    let mood: String
    let conflict: String

    init(scene: StoryAcceptanceScene) {
        location = scene.location
        timeOfDay = scene.timeOfDay
        mood = scene.mood
        conflict = scene.conflict
    }

    private enum CodingKeys: String, CodingKey {
        case location
        case timeOfDay = "time_of_day"
        case mood
        case conflict
    }
}

private struct StoryAcceptanceStoryStateOutput: Encodable {
    let activeGoal: String
    let relationshipStage: String
    let activeCharacter: String

    init(state: StoryAcceptanceStoryState) {
        activeGoal = state.activeGoal
        relationshipStage = state.relationshipStage
        activeCharacter = state.activeCharacter
    }

    private enum CodingKeys: String, CodingKey {
        case activeGoal = "active_goal"
        case relationshipStage = "relationship_stage"
        case activeCharacter = "active_character"
    }
}

private struct StoryAcceptanceCharacterOutput: Encodable {
    let name: String
    let purpose: String
    let relationship: String

    init(character: StoryAcceptanceCharacter) {
        name = character.name
        purpose = character.purpose
        relationship = character.relationship
    }
}

private struct StoryAcceptanceSeedRecord: Encodable {
    let requested: Int
    let effective: Int
    let mode: String
}

private struct StoryAcceptanceCanaryRecord: Encodable {
    let initiativeEnabled: Bool
    let activationSource: String

    private enum CodingKeys: String, CodingKey {
        case initiativeEnabled = "initiative_enabled"
        case activationSource = "activation_source"
    }
}

private struct StoryAcceptanceLatencyRecord: Encodable {
    let model: Double
    let turnEndToEnd: Double

    private enum CodingKeys: String, CodingKey {
        case model
        case turnEndToEnd = "turn_end_to_end"
    }
}

private struct StoryAcceptanceTurnArtifacts {
    let generation: StoryAcceptanceGenerationRecord
    let ratingInput: StoryAcceptanceRatingInput
}

private struct StoryAcceptanceRuntimeObservation {
    let record: StoryAcceptanceRuntimeRecord
    let promptSHA256: String
}

private struct StoryAcceptanceRuntimeRecord: Encodable {
    let provider: String
    let backend: String
    let modelIdentity: String
    let modelIdentityObserved: Bool
    let modelSHA256: String?
    let promptObserved: Bool
    let effectiveSeed: UInt32?
    let seedMode: String?
    let failureCode: String?

    private enum CodingKeys: String, CodingKey {
        case provider
        case backend
        case modelIdentity = "model_identity"
        case modelIdentityObserved = "model_identity_observed"
        case modelSHA256 = "model_sha256"
        case promptObserved = "prompt_observed"
        case effectiveSeed = "effective_seed"
        case seedMode = "seed_mode"
        case failureCode = "failure_code"
    }
}

private struct StoryAcceptanceGenerationRecord: Encodable {
    let schemaVersion: Int
    let recordType: String
    let pairID: String
    let language: String
    let model: String
    let scenarioID: String
    let scenarioVersion: String
    let fixtureSHA256: String
    let promptSHA256: String
    let pairInputSHA256: String
    let seed: StoryAcceptanceSeedRecord
    let condition: String
    let status: String
    let canary: StoryAcceptanceCanaryRecord
    let latency: StoryAcceptanceLatencyRecord
    let runtime: StoryAcceptanceRuntimeRecord

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordType = "record_type"
        case pairID = "pair_id"
        case language
        case model
        case scenarioID = "scenario_id"
        case scenarioVersion = "scenario_version"
        case fixtureSHA256 = "fixture_sha256"
        case promptSHA256 = "prompt_sha256"
        case pairInputSHA256 = "pair_input_sha256"
        case seed
        case condition
        case status
        case canary
        case latency = "latency_ms"
        case runtime
    }
}

/// Raw response/context used only to build a local blind-rating artifact.
/// This is intentionally a separate Encodable type and path from the
/// generation metadata JSONL.
private struct StoryAcceptanceRatingInput: Encodable {
    let schemaVersion: Int
    let recordType: String
    let pairID: String
    let condition: String
    let status: String
    let context: StoryAcceptanceContext
    let responseText: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordType = "record_type"
        case pairID = "pair_id"
        case condition
        case status
        case context
        case responseText = "response_text"
    }
}

private extension StoryGenerationModel {
    var acceptanceName: String {
        switch self {
        case .e4b: return "iori"
        case .b31: return "nagi"
        }
    }
}
