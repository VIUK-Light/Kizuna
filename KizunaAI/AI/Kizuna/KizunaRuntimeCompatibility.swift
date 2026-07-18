import Foundation

/// AIToolCatalog が OpenAI 互換の tool schema を組み立てるための最小表現。
/// AI Studio のディレクティブ解析本体は独立版には持ち込まない。
final class ModelDirectiveResponseSchema: Encodable {
    let type: String
    let properties: [String: ModelDirectiveResponseSchema]?
    let required: [String]?
    let enumValues: [String]?
    let nullable: Bool?
    let items: ModelDirectiveResponseSchema?

    init(
        type: String,
        properties: [String: ModelDirectiveResponseSchema]? = nil,
        required: [String]? = nil,
        enumValues: [String]? = nil,
        nullable: Bool? = nil,
        items: ModelDirectiveResponseSchema? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
        self.enumValues = enumValues
        self.nullable = nullable
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case properties
        case required
        case enumValues = "enum"
        case nullable
        case items
    }
}

/// ローカル推論ブリッジがストリーミング中に通知する状態。
/// 表示専用の AI Studio モデルから、ランタイムに必要な値だけを分離している。
enum LocalRuntimeWarmState: String, Codable, Hashable {
    case coldStart
    case warming
    case warmReady
    case reusedWarmSession
}

enum LocalExecutionStage: String, Codable, Hashable {
    case preparing
    case routing
    case warmingRuntime
    case loadingModel
    case searchPlanning
    case searching
    case thinking
    case generating
    case streaming
    case completed
    case failed
}

struct LocalExecutionStatusUpdate: Codable, Hashable {
    let stage: LocalExecutionStage
    let title: String
    let detail: String
    let estimatedProgress: Int
    let runnerLabel: String?
    let warmState: LocalRuntimeWarmState?
    let elapsedSeconds: TimeInterval

    init(
        stage: LocalExecutionStage,
        title: String,
        detail: String,
        estimatedProgress: Int,
        runnerLabel: String? = nil,
        warmState: LocalRuntimeWarmState? = nil,
        elapsedSeconds: TimeInterval = 0
    ) {
        self.stage = stage
        self.title = title
        self.detail = detail
        self.estimatedProgress = min(max(estimatedProgress, 0), 100)
        let normalizedRunnerLabel = runnerLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.runnerLabel = normalizedRunnerLabel?.isEmpty == false ? normalizedRunnerLabel : nil
        self.warmState = warmState
        self.elapsedSeconds = max(0, elapsedSeconds)
    }
}

/// Runtime bridge用の値型だけを残した互換名前空間。
/// VIUK Oneの巨大なAICoachService実装や購読・ブラウザ状態には依存しない。
enum AICoachService {
    enum CoachMode: String, CaseIterable, Identifiable {
        case studio = "AI Studio"
        case child = "子ども用"
        case guardian = "保護者用"

        var id: String { rawValue }
        var isGuardian: Bool { self == .guardian }
    }

    struct PageInfo {
        let url: String
        let title: String
        let content: String?
    }

    struct SafetySnapshot {
        let level: String
        let summary: String
        let recommendations: [String]
    }

    struct ChatMessage: Identifiable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        let content: String

        init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }
}
