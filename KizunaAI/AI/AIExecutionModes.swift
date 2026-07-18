/*
仕様:
- 役割: AIチャットの推論モード、実行設定、思考タイムラインの共通型を定義する。
- 主な型: `ReasoningMode`, `ThinkingLevel`, `AIExecutionConfig`, `ThoughtStep`.
- 編集ポイント: モード追加、検索上限、思考表示ポリシー、補助モデル上限を変えるときに触る。
*/
import Foundation

enum ReasoningMode: String, Codable, CaseIterable, Identifiable {
    case fast
    case thinking
    case deepThinking
    /// 絆会話モード。設定したキャラ (名前・性格・口調) と自由に会話する。
    /// 内部的には fast 相当 (thinking なし・短文) で動き、専用 system prompt に切り替わる。
    case persona

    var id: String { rawValue }

    /// thinking や検索向けの「推論モード」として一般化できるか。
    /// persona はキャラ会話なので thinking と同じ扱いはしない (fast 相当)。
    var isFastLike: Bool {
        switch self {
        case .fast, .persona: return true
        case .thinking, .deepThinking: return false
        }
    }

    var displayName: String {
        switch self {
        case .fast: return "高速"
        case .thinking: return "Thinking"
        case .deepThinking: return "高精度"
        case .persona: return "絆"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .fast: return "Fast"
        case .thinking: return "Think"
        case .deepThinking: return "精度"
        case .persona: return "Kizuna"
        }
    }

    var iconName: String {
        switch self {
        case .fast: return "bolt.fill"
        case .thinking: return "brain.head.profile"
        case .deepThinking: return "sparkles.rectangle.stack.fill"
        case .persona: return "infinity.circle.fill"
        }
    }

    var detailText: String {
        switch self {
        case .fast:
            return "最短で返します。雑談や短い質問向けです。"
        case .thinking:
            return "Gemma の Thinking で少し丁寧に整理します。通常の調べ物向けです。"
        case .deepThinking:
            return "Gemma 4 の思考量を増やし、比較や複雑な判断を安定させます。"
        case .persona:
            return "絆のキャラライブラリーや設定済みキャラと、関係性を覚えながら会話します。名前・性格・口調・距離感に合わせて応答します。"
        }
    }

    var recommendedUseText: String {
        switch self {
        case .fast:
            return "向いている用途: 雑談、短い確認、すぐ答えが欲しい時"
        case .thinking:
            return "向いている用途: 仕様確認、軽い比較、少し考えて答えてほしい時"
        case .deepThinking:
            return "向いている用途: 複雑な比較、設計相談、長めに考えてほしい時"
        case .persona:
            return "向いている用途: 絆キャラとの会話、寄り添ってほしい時、ロールプレイ"
        }
    }
}

enum ResearchMode: String, Codable, CaseIterable, Identifiable {
    case off
    case on
    case deep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "検索OFF"
        case .on: return "検索ON"
        case .deep: return "Deep Research"
        }
    }
}

enum ThinkingLevel: String, Codable, CaseIterable, Identifiable {
    case standard
    case extended

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "標準"
        case .extended: return "拡張"
        }
    }
}

enum SupportModel: String, Codable, CaseIterable, Identifiable {
    case none
    /// 旧 Gemini Lite 枠。Gemini は廃止済み。保存データ互換のため残すがローカル扱い。
    case geminiLite
    /// 旧 Gemini Flash 枠。Gemini は廃止済み。保存データ互換のため残すがローカル扱い。
    case geminiFlash
    case localGemma3Mini

    var id: String { rawValue }

    /// Gemini 枠を含め、ローカル Gemma 3 270M として扱う
    var isLocalModel: Bool {
        self != .none
    }

    var displayName: String {
        switch self {
        case .none: return "なし"
        case .geminiLite, .geminiFlash: return "Gemma 3 270M"
        case .localGemma3Mini: return "Gemma 3 270M"
        }
    }
}

enum SupportAgentRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case planner
    case auditor
    case architect

    var id: String { rawValue }

    var displayName: String {
        rawValue
    }

    var japaneseLabel: String {
        switch self {
        case .planner:
            return "論点整理"
        case .auditor:
            return "根拠監査"
        case .architect:
            return "構成設計"
        }
    }
}

enum GemmaSafetyProfile: String, Codable, CaseIterable, Identifiable {
    case auto
    case strict
    case balanced
    case relaxed
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "Auto"
        case .strict:
            return "厳格"
        case .balanced:
            return "標準"
        case .relaxed:
            return "緩め"
        case .custom:
            return "カスタム"
        }
    }

    var detailText: String {
        switch self {
        case .auto:
            return "Gemma の標準ガードレールを基準に使います。必要ならカテゴリ別で上書きします。"
        case .strict:
            return "不確かな内容は控えめにし、確認や根拠を優先します。"
        case .balanced:
            return "安全性と自然な会話のバランスを取ります。"
        case .relaxed:
            return "自然な返答を優先しつつ、明確な危険だけは避けます。"
        case .custom:
            return "カテゴリ別のしきい値を優先して使います。"
        }
    }

    var promptInstruction: String {
        switch self {
        case .auto:
            return "Gemma の標準 safety ガードレールを基準にし、危険・違法・年齢不適切な方向へ寄せないでください。"
        case .strict:
            return "不確かな内容は断定せず、危険・違法・年齢不適切な方向へ強く寄せないでください。"
        case .balanced:
            return "役に立つ自然な返答を優先しつつ、危険や不確かな断定は避けてください。"
        case .relaxed:
            return "自然で柔らかい返答を優先しつつ、明らかな危険や違法な依頼は避けてください。"
        case .custom:
            return "カテゴリ別の安全しきい値を優先しつつ、危険・違法・年齢不適切な方向へ寄せないでください。"
        }
    }
}

enum GemmaSafetyCategory: String, Codable, CaseIterable, Identifiable {
    case dangerousContent
    case harassment
    case hate
    case sexuallyExplicit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dangerousContent:
            return "危険行為"
        case .harassment:
            return "嫌がらせ"
        case .hate:
            return "ヘイト"
        case .sexuallyExplicit:
            return "性的表現"
        }
    }

    var detailText: String {
        switch self {
        case .dangerousContent:
            return "自傷、違法、危険な実行手順をどこまで強く抑えるかです。"
        case .harassment:
            return "侮辱、いじめ、攻撃的な表現をどこまで抑えるかです。"
        case .hate:
            return "差別や排除につながる表現をどこまで抑えるかです。"
        case .sexuallyExplicit:
            return "露骨な性的内容や年齢不適切な表現をどこまで抑えるかです。"
        }
    }
}

enum GemmaSafetyThreshold: String, Codable, CaseIterable, Identifiable {
    case off
    case standard
    case strict

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "オフ"
        case .standard:
            return "標準"
        case .strict:
            return "厳格"
        }
    }

    func instruction(for category: GemmaSafetyCategory) -> String {
        switch (category, self) {
        case (_, .off):
            return "\(category.displayName) は Gemma の標準判断を維持してください。"
        case (.dangerousContent, .standard):
            return "危険行為は Gemma の標準ガードレールで抑え、危険手順は確認寄りに返してください。"
        case (.dangerousContent, .strict):
            return "危険行為は強く抑え、手順化や具体化を避けて安全な代替だけを返してください。"
        case (.harassment, .standard):
            return "嫌がらせや攻撃的表現は抑えめにし、落ち着いた表現へ寄せてください。"
        case (.harassment, .strict):
            return "嫌がらせや攻撃的表現は強く抑え、侮辱や煽りは生成しないでください。"
        case (.hate, .standard):
            return "ヘイトや差別につながる表現は避け、中立で安全な表現へ寄せてください。"
        case (.hate, .strict):
            return "ヘイトや差別につながる表現は強く抑え、対象集団への攻撃や排除は生成しないでください。"
        case (.sexuallyExplicit, .standard):
            return "性的表現は控えめにし、露骨な内容は避けてください。"
        case (.sexuallyExplicit, .strict):
            return "性的表現は強く抑え、露骨な内容や年齢不適切な描写は生成しないでください。"
        }
    }
}

/// llama-server の投機デコード方式。
/// `auto` を選ぶと、バンドル llama-server バイナリの help を解析し、
/// 利用可能な最良のオプション（mtp > ngram-map-k4v > ngram-cache > off）を自動選択する。
enum SpeculativeDecodingMode: String, Codable, CaseIterable, Identifiable {
    case off               // 投機デコード無効
    case auto              // 利用可能な最良の方式を自動選択
    case ngramCache        // n-gram-cache (古典的、確実に動作)
    case ngramSimple       // n-gram-simple
    case ngramMapK         // n-gram-map-k
    case ngramMapK4V       // n-gram-map-k4v (新しい n-gram バリアント、精度高め)
    case ngramMod          // n-gram-mod (modular n-gram)
    case mtp               // 真の Multi-Token Prediction (Gemma 4 など、対応モデル + 対応バイナリが必要)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "OFF"
        case .auto: return "自動"
        case .ngramCache: return "n-gram (cache)"
        case .ngramSimple: return "n-gram (simple)"
        case .ngramMapK: return "n-gram (map-k)"
        case .ngramMapK4V: return "n-gram (map-k4v)"
        case .ngramMod: return "n-gram (mod)"
        case .mtp: return "MTP (Gemma 4 公式)"
        }
    }

    var detailText: String {
        switch self {
        case .off:
            return "投機デコードを無効にします。安定性最優先。"
        case .auto:
            return "推奨。バンドル llama-server とモデルから最適な方式を自動選択します。"
        case .ngramCache:
            return "古典的な n-gram キャッシュ。互換性が高く、軽い高速化。"
        case .ngramSimple:
            return "シンプルな n-gram 推測。"
        case .ngramMapK:
            return "n-gram-map-k による推測。"
        case .ngramMapK4V:
            return "新しい n-gram バリアント。チャットで 10〜30% 高速化。"
        case .ngramMod:
            return "modular n-gram。実験的。"
        case .mtp:
            return "Google 公式の Multi-Token Prediction。最大 3 倍高速化。Gemma 4 + 対応 llama-server ビルドが必要。未対応の場合は自動的に n-gram にフォールバックします。"
        }
    }

    /// 対応する `--spec-type` 引数 (`auto` / `mtp` 自動検出用は別ロジック)。
    /// `off` と `auto` は nil を返す（呼び出し側で処理）。
    var rawSpecType: String? {
        switch self {
        case .off, .auto: return nil
        case .ngramCache: return "ngram-cache"
        case .ngramSimple: return "ngram-simple"
        case .ngramMapK: return "ngram-map-k"
        case .ngramMapK4V: return "ngram-map-k4v"
        case .ngramMod: return "ngram-mod"
        case .mtp: return "mtp"
        }
    }
}

struct GemmaAdvancedSettings: Codable, Hashable {
    var safetyProfile: GemmaSafetyProfile
    var safetyThresholds: [String: GemmaSafetyThreshold]
    var useAutomaticTemperature: Bool
    var temperature: Double
    var allowToolUsage: Bool
    var strictJSONToolCalls: Bool
    var allowDirectAnswersWithoutTools: Bool
    var requireSearchForFactualQueries: Bool
    var requireExternalSourcesInDeepResearch: Bool
    var maxToolRounds: Int
    var maxSearchRounds: Int
    var enabledTools: [String: Bool]
    /// 投機デコードのモード。デフォルトは `.auto`。
    var speculativeDecodingMode: SpeculativeDecodingMode

    private enum CodingKeys: String, CodingKey {
        case safetyProfile
        case safetyThresholds
        case useAutomaticTemperature
        case temperature
        case allowToolUsage
        case strictJSONToolCalls
        case allowDirectAnswersWithoutTools
        case requireSearchForFactualQueries
        case requireExternalSourcesInDeepResearch
        case maxToolRounds
        case maxSearchRounds
        case enabledTools
        case speculativeDecodingMode
    }

    static var `default`: GemmaAdvancedSettings {
        GemmaAdvancedSettings(
            safetyProfile: .auto,
            safetyThresholds: presetThresholds(for: .auto),
            useAutomaticTemperature: true,
            temperature: 0.45,
            allowToolUsage: true,
            strictJSONToolCalls: true,
            allowDirectAnswersWithoutTools: true,
            requireSearchForFactualQueries: true,
            requireExternalSourcesInDeepResearch: true,
            maxToolRounds: 8,
            maxSearchRounds: 10,
            enabledTools: Dictionary(uniqueKeysWithValues: AIToolCatalog.toolNames.map { ($0, true) }),
            speculativeDecodingMode: .auto
        )
    }

    static func presetThresholds(for profile: GemmaSafetyProfile) -> [String: GemmaSafetyThreshold] {
        Dictionary(
            uniqueKeysWithValues: GemmaSafetyCategory.allCases.map { category in
                let threshold: GemmaSafetyThreshold
                switch profile {
                case .auto:
                    threshold = switch category {
                    case .dangerousContent, .hate, .sexuallyExplicit:
                        .strict
                    case .harassment:
                        .standard
                    }
                case .strict:
                    threshold = .strict
                case .balanced:
                    threshold = switch category {
                    case .dangerousContent, .hate:
                        .strict
                    case .harassment, .sexuallyExplicit:
                        .standard
                    }
                case .relaxed:
                    threshold = switch category {
                    case .dangerousContent, .hate:
                        .standard
                    case .harassment, .sexuallyExplicit:
                        .off
                    }
                case .custom:
                    threshold = .standard
                }
                return (category.rawValue, threshold)
            }
        )
    }

    // `nonisolated` を明示することで、`LocalAssistantRuntimeBridge` 等の
    // nonisolated コンテキストから安全に呼び出せる (Strict Concurrency 警告対策)。
    nonisolated init(
        safetyProfile: GemmaSafetyProfile,
        safetyThresholds: [String: GemmaSafetyThreshold],
        useAutomaticTemperature: Bool,
        temperature: Double,
        allowToolUsage: Bool,
        strictJSONToolCalls: Bool,
        allowDirectAnswersWithoutTools: Bool,
        requireSearchForFactualQueries: Bool,
        requireExternalSourcesInDeepResearch: Bool,
        maxToolRounds: Int,
        maxSearchRounds: Int,
        enabledTools: [String: Bool],
        speculativeDecodingMode: SpeculativeDecodingMode = .auto
    ) {
        self.safetyProfile = safetyProfile
        self.safetyThresholds = safetyThresholds
        self.useAutomaticTemperature = useAutomaticTemperature
        self.temperature = temperature
        self.allowToolUsage = allowToolUsage
        self.strictJSONToolCalls = strictJSONToolCalls
        self.allowDirectAnswersWithoutTools = allowDirectAnswersWithoutTools
        self.requireSearchForFactualQueries = requireSearchForFactualQueries
        self.requireExternalSourcesInDeepResearch = requireExternalSourcesInDeepResearch
        self.maxToolRounds = maxToolRounds
        self.maxSearchRounds = maxSearchRounds
        self.enabledTools = enabledTools
        self.speculativeDecodingMode = speculativeDecodingMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GemmaAdvancedSettings.default
        safetyProfile = try container.decodeIfPresent(GemmaSafetyProfile.self, forKey: .safetyProfile) ?? defaults.safetyProfile
        safetyThresholds = try container.decodeIfPresent([String: GemmaSafetyThreshold].self, forKey: .safetyThresholds) ?? defaults.safetyThresholds
        useAutomaticTemperature = try container.decodeIfPresent(Bool.self, forKey: .useAutomaticTemperature) ?? true
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
        allowToolUsage = try container.decodeIfPresent(Bool.self, forKey: .allowToolUsage) ?? defaults.allowToolUsage
        strictJSONToolCalls = try container.decodeIfPresent(Bool.self, forKey: .strictJSONToolCalls) ?? defaults.strictJSONToolCalls
        allowDirectAnswersWithoutTools = try container.decodeIfPresent(Bool.self, forKey: .allowDirectAnswersWithoutTools) ?? defaults.allowDirectAnswersWithoutTools
        requireSearchForFactualQueries = try container.decodeIfPresent(Bool.self, forKey: .requireSearchForFactualQueries) ?? defaults.requireSearchForFactualQueries
        requireExternalSourcesInDeepResearch = try container.decodeIfPresent(Bool.self, forKey: .requireExternalSourcesInDeepResearch) ?? defaults.requireExternalSourcesInDeepResearch
        maxToolRounds = try container.decodeIfPresent(Int.self, forKey: .maxToolRounds) ?? defaults.maxToolRounds
        maxSearchRounds = try container.decodeIfPresent(Int.self, forKey: .maxSearchRounds) ?? defaults.maxSearchRounds
        enabledTools = try container.decodeIfPresent([String: Bool].self, forKey: .enabledTools) ?? defaults.enabledTools
        speculativeDecodingMode = try container.decodeIfPresent(SpeculativeDecodingMode.self, forKey: .speculativeDecodingMode) ?? defaults.speculativeDecodingMode
    }

    var clampedTemperature: Double {
        min(max(temperature, 0.0), 1.2)
    }

    var temperatureSummary: String {
        useAutomaticTemperature ? "Auto" : String(format: "%.2f", clampedTemperature)
    }

    var clampedMaxToolRounds: Int {
        min(max(maxToolRounds, 1), 12)
    }

    var clampedMaxSearchRounds: Int {
        min(max(maxSearchRounds, 1), 16)
    }

    func isToolEnabled(_ toolName: String) -> Bool {
        allowToolUsage && (enabledTools[toolName] ?? true)
    }

    func safetyThreshold(for category: GemmaSafetyCategory) -> GemmaSafetyThreshold {
        safetyThresholds[category.rawValue] ?? .standard
    }

    func safetyInstructionLines() -> [String] {
        var lines = [safetyProfile.promptInstruction]
        for category in GemmaSafetyCategory.allCases {
            lines.append(safetyThreshold(for: category).instruction(for: category))
        }
        return lines
    }

    func normalized() -> GemmaAdvancedSettings {
        var normalizedTools = Dictionary(uniqueKeysWithValues: AIToolCatalog.toolNames.map { ($0, enabledTools[$0] ?? true) })
        for (name, value) in enabledTools where normalizedTools[name] == nil {
            normalizedTools[name] = value
        }
        var normalizedThresholds = Dictionary(
            uniqueKeysWithValues: GemmaSafetyCategory.allCases.map { category in
                (category.rawValue, safetyThreshold(for: category))
            }
        )
        for (name, value) in safetyThresholds where normalizedThresholds[name] == nil {
            normalizedThresholds[name] = value
        }

        return GemmaAdvancedSettings(
            safetyProfile: safetyProfile,
            safetyThresholds: normalizedThresholds,
            useAutomaticTemperature: useAutomaticTemperature,
            temperature: clampedTemperature,
            allowToolUsage: allowToolUsage,
            strictJSONToolCalls: strictJSONToolCalls,
            allowDirectAnswersWithoutTools: allowDirectAnswersWithoutTools,
            requireSearchForFactualQueries: requireSearchForFactualQueries,
            requireExternalSourcesInDeepResearch: requireExternalSourcesInDeepResearch,
            maxToolRounds: clampedMaxToolRounds,
            maxSearchRounds: clampedMaxSearchRounds,
            enabledTools: normalizedTools,
            speculativeDecodingMode: speculativeDecodingMode
        )
    }
}

struct AIExecutionConfig: Codable {
    let reasoningMode: ReasoningMode
    let researchMode: ResearchMode?
    let thinkingLevel: ThinkingLevel?
    let showThoughts: Bool
    let allowWebSearch: Bool
    let maxSearchCalls: Int
    let allowImageAnalysis: Bool
    let imageAnalysisDetailLevel: Int
    let allowSupportModels: Bool
    let maxSupportModelCalls: Int
    let allowToolUsage: Bool
    let selfCheckEnabled: Bool

    static func make(
        reasoningMode: ReasoningMode,
        researchMode: ResearchMode,
        thinkingLevel: ThinkingLevel
    ) -> AIExecutionConfig {
        switch reasoningMode {
        case .fast:
            return AIExecutionConfig(
                reasoningMode: .fast,
                researchMode: researchMode,
                thinkingLevel: nil,
                showThoughts: false,
                allowWebSearch: researchMode != .off,
                maxSearchCalls: researchMode == .off ? 0 : (researchMode == .deep ? 4 : 2),
                allowImageAnalysis: true,
                imageAnalysisDetailLevel: 1,
                allowSupportModels: false,
                maxSupportModelCalls: 0,
                allowToolUsage: true,
                selfCheckEnabled: researchMode == .deep
            )
        case .persona:
            // 恋愛モード: Web 検索・補助モデル・思考は全て無効。短いやり取りに最適化。
            return AIExecutionConfig(
                reasoningMode: .persona,
                researchMode: .off,
                thinkingLevel: nil,
                showThoughts: false,
                allowWebSearch: false,
                maxSearchCalls: 0,
                allowImageAnalysis: false,
                imageAnalysisDetailLevel: 0,
                allowSupportModels: false,
                maxSupportModelCalls: 0,
                allowToolUsage: false,
                selfCheckEnabled: false
            )
        case .thinking:
            let effectiveResearchMode: ResearchMode = researchMode == .deep ? .deep : .on
            let extended = thinkingLevel == .extended
            let deepResearch = effectiveResearchMode == .deep
            return AIExecutionConfig(
                reasoningMode: .thinking,
                researchMode: effectiveResearchMode,
                thinkingLevel: thinkingLevel,
                showThoughts: true,
                allowWebSearch: true,
                maxSearchCalls: deepResearch ? (extended ? 12 : 10) : (extended ? 7 : 5),
                allowImageAnalysis: true,
                imageAnalysisDetailLevel: extended ? 3 : 2,
                allowSupportModels: extended,
                maxSupportModelCalls: extended ? (deepResearch ? 4 : 2) : 0,
                allowToolUsage: true,
                selfCheckEnabled: true
            )
        case .deepThinking:
            let effectiveResearchMode: ResearchMode = researchMode == .deep ? .deep : .on
            let deepResearch = effectiveResearchMode == .deep
            return AIExecutionConfig(
                reasoningMode: .deepThinking,
                researchMode: effectiveResearchMode,
                thinkingLevel: nil,
                showThoughts: true,
                allowWebSearch: true,
                maxSearchCalls: deepResearch ? 16 : 10,
                allowImageAnalysis: true,
                imageAnalysisDetailLevel: 4,
                allowSupportModels: true,
                maxSupportModelCalls: deepResearch ? 5 : 3,
                allowToolUsage: true,
                selfCheckEnabled: true
            )
        }
    }

    var displayName: String {
        switch reasoningMode {
        case .fast:
            switch researchMode {
            case .off?: return "Fast"
            case .on?: return "Fast + Search"
            case .deep?: return "Fast + Deep Research"
            case nil: return "Fast"
            }
        case .thinking:
            let base = thinkingLevel == .extended ? "Thinking（拡張）" : "Thinking"
            if researchMode == .deep {
                return base + " + Deep Research"
            }
            return base + " + Search"
        case .deepThinking:
            return researchMode == .deep ? "高精度 + Deep Research" : "高精度 + Search"
        case .persona:
            return "恋愛"
        }
    }
}

enum ThoughtStepType: String, Codable {
    case planning
    case search
    case tool
    case imageAnalysis
    case supportModel
    case synthesis
    case finalization
}

struct ThoughtStep: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let title: String
    let detail: String?
    let type: ThoughtStepType

    init(id: UUID = UUID(), timestamp: Date = Date(), title: String, detail: String? = nil, type: ThoughtStepType) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.detail = detail
        self.type = type
    }
}
