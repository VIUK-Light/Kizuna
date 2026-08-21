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
    /// Kizuna会話モード。設定したキャラ (名前・性格・口調) と自由に会話する。
    /// Gemma 4 の Thinking を内部で有効にしつつ、短い会話本文だけを表示する。
    case persona

    var id: String { rawValue }

    /// thinking や検索向けの「推論モード」として一般化できるか。
    /// persona はキャラ会話だが、コンテキスト維持のため内部Thinkingを使う。
    var isFastLike: Bool {
        switch self {
        case .fast: return true
        case .thinking, .deepThinking, .persona: return false
        }
    }

    var displayName: String {
        switch self {
        case .fast: return "高速"
        case .thinking: return "Thinking"
        case .deepThinking: return "高精度"
        case .persona: return "kizuna"
        }
    }

    /// UI-only label. Keep `displayName` Japanese-compatible because it is
    /// also used by legacy prompt/logging paths; presentation code should use
    /// this property when the in-app language can be English.
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .fast: english = "Fast"
        case .thinking: english = "Thinking"
        case .deepThinking: english = "High accuracy"
        case .persona: english = "Kizuna"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
    }

    var shortDisplayName: String {
        switch self {
        case .fast: return "Fast"
        case .thinking: return "Think"
        case .deepThinking: return "精度"
        case .persona: return "kizuna"
        }
    }

    var localizedShortDisplayName: String {
        let english: String
        switch self {
        case .fast: english = "Fast"
        case .thinking: english = "Think"
        case .deepThinking: english = "Accuracy"
        case .persona: english = "Kizuna"
        }
        return KizunaCopy.text(japanese: shortDisplayName, english: english)
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

    var localizedDetailText: String {
        let english: String
        switch self {
        case .fast:
            english = "Replies quickly; suited to casual chat and short questions."
        case .thinking:
            english = "Uses Gemma Thinking to organize an answer more carefully; suited to ordinary research."
        case .deepThinking:
            english = "Uses more Gemma 4 reasoning to make comparisons and complex decisions more consistent."
        case .persona:
            english = "Talks with Kizuna characters while remembering their relationships, personality, voice, and distance."
        }
        return KizunaCopy.text(japanese: detailText, english: english)
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

    var localizedRecommendedUseText: String {
        let english: String
        switch self {
        case .fast:
            english = "Best for: casual chat, quick checks, and fast answers"
        case .thinking:
            english = "Best for: checking specifications, light comparisons, and answers that need a little thought"
        case .deepThinking:
            english = "Best for: complex comparisons, design discussions, and longer reasoning"
        case .persona:
            english = "Best for: talking with Kizuna characters, emotional support, and role-play"
        }
        return KizunaCopy.text(japanese: recommendedUseText, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .off: english = "Search off"
        case .on: english = "Search"
        case .deep: english = "Deep Research"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDisplayName: String {
        let english = self == .standard ? "Standard" : "Extended"
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .none:
            english = "None"
        case .geminiLite, .geminiFlash, .localGemma3Mini:
            // Legacy Gemini raw values are intentionally presented as the
            // current local compatibility slot without changing persistence.
            english = "Gemma 3 270M"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedLabel: String {
        let english: String
        switch self {
        case .planner: english = "Issue framing"
        case .auditor: english = "Evidence audit"
        case .architect: english = "Architecture design"
        }
        return KizunaCopy.text(japanese: japaneseLabel, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .auto: english = "Auto"
        case .strict: english = "Strict"
        case .balanced: english = "Balanced"
        case .relaxed: english = "Relaxed"
        case .custom: english = "Custom"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDetailText: String {
        let english: String
        switch self {
        case .auto:
            english = "Use Gemma's standard guardrails, with optional per-category overrides."
        case .strict:
            english = "Be cautious with uncertain content and prioritize verification and evidence."
        case .balanced:
            english = "Balance safety with natural conversation."
        case .relaxed:
            english = "Favor natural replies while still avoiding clear danger."
        case .custom:
            english = "Use the thresholds set for each category."
        }
        return KizunaCopy.text(japanese: detailText, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .dangerousContent: english = "Dangerous content"
        case .harassment: english = "Harassment"
        case .hate: english = "Hate"
        case .sexuallyExplicit: english = "Sexual content"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDetailText: String {
        let english: String
        switch self {
        case .dangerousContent:
            english = "How strongly to limit self-harm, illegal, or dangerous instructions."
        case .harassment:
            english = "How strongly to limit insults, bullying, and aggressive language."
        case .hate:
            english = "How strongly to limit language that promotes discrimination or exclusion."
        case .sexuallyExplicit:
            english = "How strongly to limit explicit sexual or age-inappropriate content."
        }
        return KizunaCopy.text(japanese: detailText, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .off: english = "Off"
        case .standard: english = "Standard"
        case .strict: english = "Strict"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .off: english = "Off"
        case .auto: english = "Automatic"
        case .ngramCache: english = "n-gram (cache)"
        case .ngramSimple: english = "n-gram (simple)"
        case .ngramMapK: english = "n-gram (map-k)"
        case .ngramMapK4V: english = "n-gram (map-k4v)"
        case .ngramMod: english = "n-gram (modular)"
        case .mtp: english = "MTP (official Gemma 4)"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
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

    var localizedDetailText: String {
        let english: String
        switch self {
        case .off:
            english = "Disable speculative decoding for maximum stability."
        case .auto:
            english = "Recommended. Choose the best supported mode automatically from the bundled server and model."
        case .ngramCache:
            english = "Classic n-gram cache with broad compatibility and a light speed-up."
        case .ngramSimple:
            english = "Simple n-gram prediction."
        case .ngramMapK:
            english = "Prediction using ngram-map-k."
        case .ngramMapK4V:
            english = "A newer n-gram variant that can speed up chat by 10–30%."
        case .ngramMod:
            english = "Modular n-gram; experimental."
        case .mtp:
            english = "Google's official Multi-Token Prediction. Requires Gemma 4 and a compatible llama-server build; falls back to n-gram when unavailable."
        }
        return KizunaCopy.text(japanese: detailText, english: english)
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

    /// UI-only configuration label. Keep `displayName` unchanged for legacy
    /// diagnostics and prompt-adjacent code paths.
    var localizedDisplayName: String {
        switch reasoningMode {
        case .fast:
            switch researchMode {
            case .off?, nil: return "Fast"
            case .on?: return "Fast + Search"
            case .deep?: return "Fast + Deep Research"
            }
        case .thinking:
            let base = thinkingLevel == .extended ? "Thinking (Extended)" : "Thinking"
            return researchMode == .deep ? base + " + Deep Research" : base + " + Search"
        case .deepThinking:
            return researchMode == .deep ? "High accuracy + Deep Research" : "High accuracy + Search"
        case .persona:
            return "Kizuna"
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

// MARK: - Provider-neutral generation contract

/// A provider-neutral request used by the model router. Feature-specific
/// prompt builders remain outside this type; providers only receive the
/// final system/user boundary and generation controls.
struct AIGenerationRequest: Sendable {
    let systemPrompt: String
    let userPrompt: String
    let temperature: Double
    let maxOutputTokens: Int
    let seed: Int?
    let onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)?
    let onModelResolved: (@MainActor @Sendable (AIModelIdentity) -> Void)?

    init(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.72,
        maxOutputTokens: Int = 1024,
        seed: Int? = nil,
        onUpdate: (@MainActor @Sendable (LocalAssistantStructuredTurnUpdate) -> Void)? = nil,
        onModelResolved: (@MainActor @Sendable (AIModelIdentity) -> Void)? = nil
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.temperature = temperature
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.seed = seed
        self.onUpdate = onUpdate
        self.onModelResolved = onModelResolved
    }
}

struct AIGenerationUsage: Codable, Equatable, Hashable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
}

struct AIGenerationResponse: Sendable {
    let text: String
    let identity: AIModelIdentity
    let finishReason: String?
    let usage: AIGenerationUsage?
}

enum AIProviderError: LocalizedError, Equatable {
    case configurationDisabled
    case missingCredential
    case invalidEndpoint
    case httpStatus(Int, String)
    case invalidResponse
    case emptyResponse
    case generationTruncated(String)
    case noProviderForRole(AIModelRole)

    var errorDescription: String? {
        switch self {
        case .configurationDisabled:
            return "The selected AI model configuration is disabled."
        case .missingCredential:
            return "The selected AI provider credential is not configured."
        case .invalidEndpoint:
            return "The selected AI provider endpoint is invalid."
        case let .httpStatus(status, body):
            let preview = String(body.prefix(180))
            return preview.isEmpty ? "AI provider request failed with HTTP \(status)." : "AI provider request failed with HTTP \(status): \(preview)"
        case .invalidResponse:
            return "The AI provider returned an unreadable response."
        case .emptyResponse:
            return "The AI provider returned no response text."
        case let .generationTruncated(reason):
            return "The AI provider stopped before completing the response (\(reason))."
        case let .noProviderForRole(role):
            return "No enabled AI model is configured for role \(role.rawValue)."
        }
    }
}

protocol AIProvider: AnyObject {
    var providerID: AIProviderID { get }
    func generate(
        request: AIGenerationRequest,
        configuration: AIModelConfiguration
    ) async throws -> AIGenerationResponse
}

/// Routes a role to enabled configurations in priority order. The registry
/// and credential store are independent from provider implementations, so a
/// new provider can be registered without adding another feature-specific
/// switch to Persona or Story.
@MainActor
final class AIModelRouter {
    static let shared = AIModelRouter()

    private let registry: AIModelRegistry
    private var providers: [AIProviderID: AIProvider]

    init(registry: AIModelRegistry = .shared) {
        self.registry = registry
        self.providers = [:]
        register(LocalAIProvider())
        register(GoogleGenerativeLanguageProvider())
        register(OpenAICompatibleProvider())
        register(AnthropicProvider())
    }

    func register(_ provider: AIProvider) {
        providers[provider.providerID] = provider
    }

    func generate(
        request: AIGenerationRequest,
        configurationID: UUID
    ) async throws -> AIGenerationResponse {
        guard let configuration = registry.configuration(id: configurationID) else {
            throw AIProviderError.invalidResponse
        }
        guard configuration.isEnabled else {
            throw AIProviderError.configurationDisabled
        }
        guard let provider = providers[configuration.identity.providerID] else {
            throw AIProviderError.invalidResponse
        }
        return try await provider.generate(request: request, configuration: configuration)
    }

    func generate(
        request: AIGenerationRequest,
        role: AIModelRole,
        preferredConfigurationID: UUID? = nil,
        allowsFallback: Bool = true
    ) async throws -> AIGenerationResponse {
        var configurations = registry.configurations(for: role)
        if let preferredConfigurationID,
           let index = configurations.firstIndex(where: { $0.id == preferredConfigurationID }) {
            let preferred = configurations.remove(at: index)
            configurations.insert(preferred, at: 0)
        }
        guard !configurations.isEmpty else {
            throw AIProviderError.noProviderForRole(role)
        }

        if !allowsFallback {
            guard let preferredConfigurationID,
                  configurations.contains(where: { $0.id == preferredConfigurationID }) else {
                throw AIProviderError.noProviderForRole(role)
            }
            return try await generate(request: request, configurationID: preferredConfigurationID)
        }

        var lastError: Error?
        for configuration in configurations {
            do {
                return try await generate(request: request, configurationID: configuration.id)
            } catch {
                lastError = error
                AppLog.note(
                    "[AIModelRouter] provider failed role=%@ config=%@ error=%@",
                    role.rawValue,
                    configuration.identity.stableID,
                    error.localizedDescription
                )
                if let providerError = error as? AIProviderError,
                   case .generationTruncated = providerError {
                    throw error
                }
            }
        }
        throw lastError ?? AIProviderError.noProviderForRole(role)
    }
}

@MainActor
private final class LocalAIProvider: AIProvider {
    let providerID: AIProviderID = .localRuntime

    func generate(
        request: AIGenerationRequest,
        configuration: AIModelConfiguration
    ) async throws -> AIGenerationResponse {
        let selectedModelURL = LocalAssistantModelManager.shared.modelURL(
            forArtifactID: configuration.identity.artifactID
        )
        let result = await LocalAssistantRuntimeBridge.shared.generateReply(
            prompt: request.userPrompt,
            contextPrompt: nil,
            coachMode: .studio,
            reasoningMode: .thinking,
            researchMode: .off,
            childAge: 12,
            pageInfo: nil,
            safetySnapshot: nil,
            advancedSettings: GemmaAdvancedSettings.default,
            overrideSystemPrompt: request.systemPrompt,
            overrideModelURL: selectedModelURL,
            seedOverride: request.seed.map(UInt32.init),
            onUpdate: request.onUpdate
        )
        guard let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AIProviderError.emptyResponse
        }
        let observedArtifactID = result.modelIdentity?
            .split(separator: "/")
            .last
            .map(String.init)
        let artifactID = observedArtifactID ?? configuration.identity.artifactID
        let identity = AIModelIdentity(
            providerID: .localRuntime,
            modelID: configuration.identity.modelID,
            displayName: artifactID ?? configuration.identity.displayName,
            artifactID: artifactID
        )
        request.onModelResolved?(identity)
        return AIGenerationResponse(
            text: text,
            identity: identity,
            finishReason: nil,
            usage: nil
        )
    }
}

@MainActor
private final class GoogleGenerativeLanguageProvider: AIProvider {
    let providerID: AIProviderID = .googleGenerativeLanguage

    func generate(
        request: AIGenerationRequest,
        configuration: AIModelConfiguration
    ) async throws -> AIGenerationResponse {
        guard let apiKey = AISecretStore.shared.providerAPIKey(for: configuration.id)
                ?? AISecretStore.shared.configuredGemmaWebReaderAPIKey() else {
            throw AIProviderError.missingCredential
        }

        var result: StoryGemma31BGenerationResult
        if request.onUpdate != nil {
            let accumulator = StoryGemma31BStreamAccumulator()
            do {
                result = try await StoryGemma31BAPIService.shared.generateStreaming(
                    systemPrompt: request.systemPrompt,
                    userPrompt: request.userPrompt,
                    temperature: request.temperature,
                    maxOutputTokens: request.maxOutputTokens,
                    seed: request.seed,
                    apiKey: apiKey,
                    onTextDelta: { delta in
                        let visible = accumulator.append(delta)
                        Task { @MainActor in
                            request.onUpdate?(.visiblePreview(visible))
                        }
                    },
                    onModelResolved: { modelName in
                        let identity = AIModelIdentity(
                            providerID: .googleGenerativeLanguage,
                            modelID: modelName,
                            displayName: modelName
                        )
                        Task { @MainActor in
                            request.onModelResolved?(identity)
                        }
                    }
                )
            } catch let error as StoryGemma31BAPIError {
                if case let .truncated(reason) = error {
                    throw AIProviderError.generationTruncated(reason)
                }
                guard case let .httpStatus(status, _) = error,
                      [400, 404, 405].contains(status) else {
                    throw error
                }
                // Some deployments expose generateContent but not the SSE
                // variant. Fall back to the same provider/model request and
                // keep the lack of deltas explicit rather than faking a stream.
                result = try await StoryGemma31BAPIService.shared.generate(
                    systemPrompt: request.systemPrompt,
                    userPrompt: request.userPrompt,
                    temperature: request.temperature,
                    maxOutputTokens: request.maxOutputTokens,
                    seed: request.seed,
                    apiKey: apiKey
                )
            }
        } else {
            do {
                result = try await StoryGemma31BAPIService.shared.generate(
                    systemPrompt: request.systemPrompt,
                    userPrompt: request.userPrompt,
                    temperature: request.temperature,
                    maxOutputTokens: request.maxOutputTokens,
                    seed: request.seed,
                    apiKey: apiKey
                )
            } catch let error as StoryGemma31BAPIError {
                if case let .truncated(reason) = error {
                    throw AIProviderError.generationTruncated(reason)
                }
                throw error
            }
        }
        let usage = result.usageMetadata.map {
            AIGenerationUsage(
                promptTokens: $0.promptTokenCount,
                completionTokens: $0.candidatesTokenCount,
                totalTokens: ($0.promptTokenCount ?? 0) + ($0.candidatesTokenCount ?? 0)
            )
        }
        let response = AIGenerationResponse(
            text: result.text,
            identity: result.identity,
            finishReason: result.finishReason,
            usage: usage
        )
        request.onModelResolved?(response.identity)
        request.onUpdate?(.visiblePreview(response.text))
        return response
    }
}

private final class OpenAICompatibleProvider: AIProvider {
    let providerID: AIProviderID = .openAICompatible

    func generate(
        request: AIGenerationRequest,
        configuration: AIModelConfiguration
    ) async throws -> AIGenerationResponse {
        guard let apiKey = AISecretStore.shared.providerAPIKey(for: configuration.id) else {
            throw AIProviderError.missingCredential
        }
        let endpoint = try chatCompletionsURL(configuration.endpoint)
        var payload: [String: Any] = [
            "model": configuration.identity.modelID,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userPrompt]
            ],
            "temperature": request.temperature,
            "max_tokens": request.maxOutputTokens
        ]
        if let seed = request.seed { payload["seed"] = seed }
        let response = try await performJSONRequest(
            endpoint: endpoint,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json"
            ],
            payload: payload,
            configuration: configuration,
            responseParser: Self.parseResponse
        )
        request.onModelResolved?(response.identity)
        request.onUpdate?(.visiblePreview(response.text))
        return response
    }

    private static func parseResponse(
        object: Any,
        configuration: AIModelConfiguration
    ) throws -> AIGenerationResponse {
        guard let dictionary = object as? [String: Any],
              let choices = dictionary["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidResponse
        }
        return AIGenerationResponse(
            text: text,
            identity: configuration.identity,
            finishReason: first["finish_reason"] as? String,
            usage: parseUsage(dictionary["usage"])
        )
    }
}

private final class AnthropicProvider: AIProvider {
    let providerID: AIProviderID = .anthropic

    func generate(
        request: AIGenerationRequest,
        configuration: AIModelConfiguration
    ) async throws -> AIGenerationResponse {
        guard let apiKey = AISecretStore.shared.providerAPIKey(for: configuration.id) else {
            throw AIProviderError.missingCredential
        }
        let endpoint = try endpointURL(configuration.endpoint, defaultValue: "https://api.anthropic.com/v1/messages")
        let payload: [String: Any] = [
            "model": configuration.identity.modelID,
            "system": request.systemPrompt,
            "messages": [["role": "user", "content": request.userPrompt]],
            "temperature": request.temperature,
            "max_tokens": request.maxOutputTokens
        ]
        let response = try await performJSONRequest(
            endpoint: endpoint,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "Content-Type": "application/json"
            ],
            payload: payload,
            configuration: configuration,
            responseParser: Self.parseResponse
        )
        request.onModelResolved?(response.identity)
        request.onUpdate?(.visiblePreview(response.text))
        return response
    }

    private static func parseResponse(
        object: Any,
        configuration: AIModelConfiguration
    ) throws -> AIGenerationResponse {
        guard let dictionary = object as? [String: Any],
              let content = dictionary["content"] as? [[String: Any]] else {
            throw AIProviderError.invalidResponse
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return AIGenerationResponse(
            text: text,
            identity: configuration.identity,
            finishReason: dictionary["stop_reason"] as? String,
            usage: parseUsage(dictionary["usage"])
        )
    }
}

private func chatCompletionsURL(_ rawEndpoint: String?) throws -> URL {
    let base = try endpointURL(rawEndpoint, defaultValue: "")
    if base.path.hasSuffix("/chat/completions") { return base }
    return base.appendingPathComponent("chat/completions")
}

private func endpointURL(_ rawEndpoint: String?, defaultValue: String) throws -> URL {
    let raw = (rawEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        ? rawEndpoint!
        : defaultValue
    guard let url = URL(string: raw), url.scheme == "https", url.host != nil else {
        throw AIProviderError.invalidEndpoint
    }
    return url
}

private func performJSONRequest(
    endpoint: URL,
    headers: [String: String],
    payload: [String: Any],
    configuration: AIModelConfiguration,
    responseParser: (Any, AIModelConfiguration) throws -> AIGenerationResponse
) async throws -> AIGenerationResponse {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 90
    for (field, value) in headers {
        request.setValue(value, forHTTPHeaderField: field)
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(status) else {
            throw AIProviderError.httpStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw AIProviderError.invalidResponse
        }
        return try responseParser(object, configuration)
    } catch let error as AIProviderError {
        throw error
    } catch {
        throw AIProviderError.httpStatus(-1, error.localizedDescription)
    }
}

private func parseUsage(_ value: Any?) -> AIGenerationUsage? {
    guard let dictionary = value as? [String: Any] else { return nil }
    let prompt = (dictionary["prompt_tokens"] as? Int) ?? (dictionary["input_tokens"] as? Int)
    let completion = (dictionary["completion_tokens"] as? Int) ?? (dictionary["output_tokens"] as? Int)
    let total = (dictionary["total_tokens"] as? Int) ?? ((prompt ?? 0) + (completion ?? 0))
    return AIGenerationUsage(promptTokens: prompt, completionTokens: completion, totalTokens: total)
}
