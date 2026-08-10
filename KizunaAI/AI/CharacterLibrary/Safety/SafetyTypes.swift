/*
仕様:
- 役割: 安全性パイプラインで使う基本型一式 (Rating/Visibility/Action/Severity/Domain/Rule/Decision/Concern)。
- 主な型: SafetyRating, CharacterVisibility, SafetyAction, SafetySeverity, SafetyDomain,
         SafetyRule, SafetyDecision, SafetyConcern。
- 編集ポイント: 安全カテゴリーや判定結果の構造を変える時。
*/

import Foundation

/// 公開可能な安全レーティング (CharacterLibrary でフィルタ表示にも使う)。
enum SafetyRating: String, Codable, CaseIterable, Identifiable, Hashable {
    case general      // 一般向け
    case teen         // ティーン以上
    case sensitive    // 配慮を要する話題を含む
    case restricted   // 公開不可レベル (制限すべき)

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .general: return "一般"
        case .teen: return "13+"
        case .sensitive: return "センシティブ"
        case .restricted: return "制限"
        }
    }
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .general: english = "General"
        case .teen: english = "13+"
        case .sensitive: english = "Sensitive"
        case .restricted: english = "Restricted"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
    }
    var iconName: String {
        switch self {
        case .general: return "checkmark.seal"
        case .teen: return "13.square"
        case .sensitive: return "exclamationmark.triangle"
        case .restricted: return "xmark.octagon"
        }
    }
}

/// キャラクターの公開状態。
enum CharacterVisibility: String, Codable, CaseIterable, Identifiable, Hashable {
    case `private`    // 本人のみ
    case unlisted     // URL/ID 知ってる人のみ (将来の共有用)
    case `public`     // ライブラリーに掲載

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .private: return "非公開"
        case .unlisted: return "限定公開"
        case .public: return "公開"
        }
    }
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .private: english = "Private"
        case .unlisted: english = "Unlisted"
        case .public: english = "Public"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
    }
    var iconName: String {
        switch self {
        case .private: return "lock.fill"
        case .unlisted: return "link"
        case .public: return "globe"
        }
    }
}

/// 安全性判定の結果として取られるアクション。
enum SafetyAction: String, Codable, CaseIterable, Hashable {
    case allow         // そのまま
    case warn          // 警告のみ
    case soften        // 緩和書き換え (rewrittenText 提示)
    case block         // 通させない
    case requireEdit   // 修正必須 (保存させない / 出力させない)
}

/// 重要度。
enum SafetySeverity: String, Codable, CaseIterable, Hashable {
    case info
    case warning
    case block
}

/// 検出されたリスクのドメイン。複数同時にヒットしうる。
enum SafetyDomain: String, Codable, CaseIterable, Hashable {
    case romance
    case family
    case violence
    case crime
    case selfHarm      = "self_harm"
    case sexual
    case minors
    case personalInfo  = "personal_info"
    case harassment
    case medical
    case financial
    case legal

    var displayName: String {
        switch self {
        case .romance: return "恋愛"
        case .family: return "家族"
        case .violence: return "暴力"
        case .crime: return "犯罪"
        case .selfHarm: return "自傷"
        case .sexual: return "性的"
        case .minors: return "未成年"
        case .personalInfo: return "個人情報"
        case .harassment: return "嫌がらせ"
        case .medical: return "医療"
        case .financial: return "金融"
        case .legal: return "法律"
        }
    }
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .romance: english = "Romance"
        case .family: english = "Family"
        case .violence: english = "Violence"
        case .crime: english = "Crime"
        case .selfHarm: english = "Self-harm"
        case .sexual: english = "Sexual content"
        case .minors: english = "Minors"
        case .personalInfo: english = "Personal information"
        case .harassment: english = "Harassment"
        case .medical: english = "Medical"
        case .financial: english = "Financial"
        case .legal: english = "Legal"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
    }
}

/// 個別の安全ルール (テンプレ/UI 表示・編集用)。
struct SafetyRule: Codable, Identifiable, Equatable, Hashable {
    let id: String
    var title: String
    var description: String
    var severity: SafetySeverity
    var appliesTo: [SafetyDomain]
}

/// パイプラインの判定結果。
struct SafetyDecision: Equatable, Hashable {
    var action: SafetyAction
    var reasons: [String]
    var riskDomains: [SafetyDomain]
    var severity: SafetySeverity
    /// 緩和書き換え後のテキスト。soften/requireEdit 時に使う。
    var rewrittenText: String?
    /// 生成プロンプトに追加で差し込みたいルール (例: 「自傷の話題は専門窓口を案内する」)。
    var addedPromptRules: [String]

    init(
        action: SafetyAction = .allow,
        reasons: [String] = [],
        riskDomains: [SafetyDomain] = [],
        severity: SafetySeverity = .info,
        rewrittenText: String? = nil,
        addedPromptRules: [String] = []
    ) {
        self.action = action
        self.reasons = reasons
        self.riskDomains = riskDomains
        self.severity = severity
        self.rewrittenText = rewrittenText
        self.addedPromptRules = addedPromptRules
    }

    static let allow = SafetyDecision()
}

// MARK: - 相談サポート分類

/// 危険な相談を「会話を止める理由」ではなく、UIサポートを出す分類として扱う。
enum SafetyConcernCategory: String, CaseIterable, Hashable {
    case emotionalDistress
    case selfHarm
    case violenceOrAbuse
    case medicalUrgency
    case generalSafety

    var displayName: String {
        switch self {
        case .emotionalDistress: return "こころの悩み"
        case .selfHarm: return "自分を傷つける悩み"
        case .violenceOrAbuse: return "暴力・被害の悩み"
        case .medicalUrgency: return "体調・医療の緊急性"
        case .generalSafety: return "安全に関する悩み"
        }
    }
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .emotionalDistress: english = "Emotional distress"
        case .selfHarm: english = "Self-harm concern"
        case .violenceOrAbuse: english = "Violence or abuse"
        case .medicalUrgency: english = "Medical urgency"
        case .generalSafety: english = "General safety"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
    }
}

enum SafetyConcernLevel: String, CaseIterable, Hashable {
    case supportive
    case elevated
    case urgent

    var displayName: String {
        switch self {
        case .supportive: return "相談をおすすめ"
        case .elevated: return "早めの相談をおすすめ"
        case .urgent: return "今すぐ安全を優先"
        }
    }
    var localizedDisplayName: String {
        let english: String
        switch self {
        case .supportive: english = "Support is recommended"
        case .elevated: english = "Please consider support soon"
        case .urgent: english = "Prioritize immediate safety"
        }
        return KizunaCopy.text(japanese: displayName, english: english)
    }
}

/// UIから開ける相談先。地域・言語ごとの一覧へ差し替えられる構造にする。
struct SafetySupportResource: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let detail: String
    let actionTitle: String?
    let urlString: String?
    /// 英語UI用の表示値。保存データは日本語のままでも、表示時に言語を切り替えられる。
    let englishTitle: String?
    let englishDetail: String?
    let englishActionTitle: String?

    init(
        title: String,
        detail: String,
        actionTitle: String? = nil,
        urlString: String? = nil,
        englishTitle: String? = nil,
        englishDetail: String? = nil,
        englishActionTitle: String? = nil
    ) {
        self.id = title
        self.title = title
        self.detail = detail
        self.actionTitle = actionTitle
        self.urlString = urlString
        self.englishTitle = englishTitle
        self.englishDetail = englishDetail
        self.englishActionTitle = englishActionTitle
    }

    var localizedTitle: String {
        KizunaCopy.text(japanese: title, english: englishTitle ?? title)
    }

    var localizedDetail: String {
        KizunaCopy.text(japanese: detail, english: englishDetail ?? detail)
    }

    var localizedActionTitle: String? {
        guard let actionTitle else { return nil }
        return KizunaCopy.text(japanese: actionTitle, english: englishActionTitle ?? actionTitle)
    }
}

/// 分類機が返す相談サポート情報。会話の本文を置き換えたり、送信を止めたりしない。
struct SafetyConcern: Identifiable, Equatable, Hashable {
    let id: UUID
    let category: SafetyConcernCategory
    let level: SafetyConcernLevel
    let confidence: Double
    let title: String
    let message: String
    let resources: [SafetySupportResource]
    let englishTitle: String?
    let englishMessage: String?

    init(
        id: UUID = UUID(),
        category: SafetyConcernCategory,
        level: SafetyConcernLevel,
        confidence: Double,
        title: String = "悩みがありますか？",
        message: String,
        resources: [SafetySupportResource],
        englishTitle: String? = nil,
        englishMessage: String? = nil
    ) {
        self.id = id
        self.category = category
        self.level = level
        self.confidence = confidence
        self.title = title
        self.message = message
        self.resources = resources
        self.englishTitle = englishTitle
        self.englishMessage = englishMessage
    }

    var localizedTitle: String {
        KizunaCopy.text(japanese: title, english: englishTitle ?? "Would you like support?")
    }

    var localizedMessage: String {
        KizunaCopy.text(japanese: message, english: englishMessage ?? Self.defaultEnglishMessage(for: category))
    }

    private static func defaultEnglishMessage(for category: SafetyConcernCategory) -> String {
        switch category {
        case .selfHarm:
            return "If you may hurt yourself, you do not have to handle it alone. Consider contacting someone you trust or a professional support service."
        case .violenceOrAbuse:
            return "If your safety may be at risk, move to a safer place and contact someone you trust or a local support service."
        case .medicalUrgency:
            return "If this may be a medical emergency, contact local emergency services or a healthcare provider instead of waiting for an AI reply."
        case .emotionalDistress:
            return "If you are struggling, you can talk here and also consider reaching out to someone you trust or a professional support service."
        case .generalSafety:
            return "If your safety may be at risk, consider contacting someone you trust or a local support service."
        }
    }

    /// DEBUGビルドで相談サポートUIを確認するためのサンプル。
    static let debugSample = SafetyConcern(
        category: .emotionalDistress,
        level: .elevated,
        confidence: 1.0,
        message: "ひとりで抱え込まず、話せる人や専門の相談先につながることも選べます。",
        resources: SafetyConcern.defaultResources
    )

    /// Localeの地域ヒントに合わせた相談先。GPSや正確な居場所は取得せず、
    /// 日本以外では日本の電話番号を表示しない。地域不明時も一般的な緊急案内
    /// と国際的な窓口検索だけを提示する。
    static var defaultResources: [SafetySupportResource] {
        switch Locale.current.region?.identifier.uppercased() {
        case "JP":
            return [
                SafetySupportResource(
                    title: "こころの健康相談統一ダイヤル",
                    detail: "0570-064-556。地域の公的なこころの相談窓口につながります。受付時間は地域により異なります。",
                    actionTitle: "電話する",
                    urlString: "tel://0570064556",
                    englishTitle: "Mental Health Support Dial",
                    englishDetail: "0570-064-556 connects you with a public mental-health support service in Japan. Hours vary by region.",
                    englishActionTitle: "Call"
                ),
                SafetySupportResource(
                    title: "よりそいホットライン",
                    detail: "0120-279-338。話を聴いてほしい時の相談先です。",
                    actionTitle: "電話する",
                    urlString: "tel://0120279338",
                    englishTitle: "Yorisoi Hotline",
                    englishDetail: "0120-279-338 is a listening and support hotline in Japan.",
                    englishActionTitle: "Call"
                ),
                SafetySupportResource(
                    title: "緊急時（日本）",
                    detail: "今すぐ危険がある場合は、110（警察）または119（救急）を利用してください。",
                    englishTitle: "Emergency services (Japan)",
                    englishDetail: "If there is immediate danger in Japan, call 110 for police or 119 for an ambulance."
                ),
                SafetySupportResource(
                    title: "まもろうよ こころ",
                    detail: "電話・SNS・チャットなど、地域や状況に合う相談先を探せます。",
                    actionTitle: "相談先を見る",
                    urlString: "https://www.mhlw.go.jp/mamorouyokokoro/",
                    englishTitle: "Mamoru yo Kokoro",
                    englishDetail: "Find phone, social-media, and chat support options available in Japan.",
                    englishActionTitle: "View resources"
                )
            ]
        case "US":
            return [
                SafetySupportResource(
                    title: "988 自殺・危機支援ライン",
                    detail: "米国では988へ電話またはSMSを送ると、無料で秘密が守られる危機支援につながります。",
                    actionTitle: "988へ電話する",
                    urlString: "tel://988",
                    englishTitle: "988 Suicide & Crisis Lifeline",
                    englishDetail: "Call or text 988 for free, confidential crisis support in the United States.",
                    englishActionTitle: "Call 988"
                ),
                SafetySupportResource(
                    title: "緊急時（米国）",
                    detail: "今すぐ危険がある場合は911へ連絡してください。",
                    englishTitle: "Emergency services (United States)",
                    englishDetail: "If there is immediate danger, call 911."
                ),
                internationalResource
            ]
        default:
            return [internationalResource]
        }
    }

    private static var internationalResource: SafetySupportResource {
        SafetySupportResource(
            title: "地域の緊急窓口",
            detail: "今すぐ危険がある場合は、現在地の緊急番号または地域の医療・相談窓口に連絡してください。",
            actionTitle: "相談先を探す",
            urlString: "https://findahelpline.com/",
            englishTitle: "Local emergency services",
            englishDetail: "If there is immediate danger, contact the emergency number or healthcare/support service for your current location. You can also search local services.",
            englishActionTitle: "Find local support"
        )
    }
}
