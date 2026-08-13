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

/// Decide which output text is eligible to reach the Story persistence path.
/// A rewrite is mandatory for `.soften`; `.requireEdit` never produces a
/// persistable output, so the original model text can never fall through.
enum StoryOutputSafetyPolicy {
    static func persistableText(
        action: SafetyAction,
        original: String,
        rewritten: String?
    ) -> String? {
        switch action {
        case .block, .requireEdit:
            return nil
        case .soften:
            guard let rewritten,
                  !rewritten.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return rewritten
        case .allow, .warn:
            return original
        }
    }

    /// Model-emitted state is coupled to the text that was evaluated. A
    /// rewritten `.soften` response therefore cannot carry the original
    /// response's state delta into persistence. Only actions that preserve the
    /// evaluated text may keep its already-parsed state patch.
    static func persistableStatePatch(
        action: SafetyAction,
        original: StoryStatePatch?
    ) -> StoryStatePatch? {
        switch action {
        case .allow, .warn:
            return original
        case .soften, .block, .requireEdit:
            return nil
        }
    }
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

    /// Safety checker は保存データやプロンプトと同じ日本語の理由を返す。
    /// その値を判定ロジック側で英訳すると安全ルールの比較やテストが壊れるため、
    /// UI が表示するときだけローカライズする。
    var localizedReasons: [String] {
        reasons.map(SafetyReasonLocalization.localized)
    }
}

/// SafetyDecision の説明文だけを画面向けにローカライズする。
/// 未知の理由は原文を残し、安全警告を空文字にして意味を隠さない。
enum SafetyReasonLocalization {
    private static let englishByJapanese: [String: String] = [
        "犯罪行為の具体的な手順が含まれている可能性があります。":
            "This character may contain specific instructions for criminal acts.",
        "未成年と性的内容を組み合わせることはできません。":
            "Sexual content cannot be combined with minors.",
        "性的表現が含まれるため safetyRating の再検討を推奨します。":
            "Sexual content is present; reconsider the safety rating.",
        "家族・兄弟姉妹的な関係性で恋愛表現が含まれています。":
            "Romantic content is present in a family or sibling relationship.",
        "裏社会設定でも犯罪手順は禁止です。":
            "Criminal instructions are not allowed, even in an underworld setting.",
        "プロフィールがほぼ空です。性格や関係性を記述してください。":
            "The profile is almost empty. Describe the personality or relationship.",
        "自傷の示唆を検知しました。":
            "Possible self-harm content was detected.",
        "個人情報のやり取りが含まれている可能性があります。":
            "This may contain an exchange of personal information.",
        "犯罪行為の手順依頼を検知しました。":
            "A request for criminal instructions was detected.",
        "攻撃的な表現が含まれています。":
            "Aggressive language is present.",
        "出力に犯罪手順が含まれています。":
            "The output contains criminal instructions.",
        "一般向け設定で性的表現が含まれています。":
            "Sexual content is present in a general-audience character.",
        "保存に失敗しました。少し時間を置いて再度お試しください。":
            "Saving failed. Wait a moment and try again.",
        "保存に失敗しました。入力内容と保存先を確認して、もう一度試してください。":
            "Saving failed. Check the input and destination, then try again.",
        "ユーザーが拒否や不快感を示したら態度を和らげ、話題を変える。":
            "If the user refuses or seems uncomfortable, soften the tone and change the subject.",
        "ユーザーが不快感や拒否を示したら態度を和らげる。":
            "If the user seems uncomfortable or refuses, soften the tone.",
        "個人を特定する情報を聞き出さない。":
            "Do not ask for information that identifies a person.",
        "現実の危険行為や違法行為の手順を説明しない。":
            "Do not explain instructions for real-world dangerous or illegal acts.",
        "恋愛描写は穏やかな範囲に抑える。":
            "Keep romantic content gentle and non-explicit.",
        "強制・脅迫・監禁・支配を肯定的に描かない。":
            "Do not portray coercion, threats, captivity, or control positively.",
        "嫉妬や執着は軽い感情表現に留める。":
            "Keep jealousy and attachment to mild emotional expression.",
        "家族関係は安心できる関係として描く。":
            "Portray family relationships as safe and supportive.",
        "兄妹姉弟・親代わりは恋愛化しない。":
            "Do not turn sibling or parental relationships into romance.",
        "依存や支配を肯定しない。":
            "Do not endorse dependency or control.",
        "犯罪や危険行為の具体的手順を出さない。":
            "Do not provide specific instructions for crime or dangerous acts.",
        "暴力や犯罪を現実で実行するよう促さない。":
            "Do not encourage carrying out violence or crime in the real world.",
        "物語上の雰囲気に留める。":
            "Keep it atmospheric and fictional.",
        "過度な残虐描写を避ける。":
            "Avoid excessive graphic violence.",
        "恐怖演出は雰囲気中心にする。":
            "Keep horror focused on atmosphere.",
        "現実の危険行為につながる指示を出さない。":
            "Do not give instructions that could lead to real-world harm.",
        "暴力描写は雰囲気の範囲に留める。":
            "Keep violence within an atmospheric, non-instructional range.",
        "現実の戦闘技術を具体化しない。":
            "Do not provide concrete real-world combat techniques.",
        "医療・法律・金融などの高リスク領域では断定しすぎない。":
            "Avoid definitive claims in high-risk areas such as medical, legal, or financial topics.",
        "必要に応じて専門家への相談を促す。":
            "Encourage consulting a qualified professional when appropriate.",
        "未成年キャラクターの場合、性的描写を避ける。":
            "Avoid sexual content for minor characters.",
        "家族・兄弟姉妹的関係は恋愛化しない。":
            "Do not turn family or sibling relationships into romance.",
        "支配や従属を美化しすぎない。":
            "Do not excessively glamorize domination or submission.",
        "現実的な人権侵害を肯定する描写は避ける。":
            "Avoid portraying real-world human-rights abuses as acceptable.",
        "競争は健全な範囲に留め、暴力や侮辱を煽らない。":
            "Keep competition healthy and do not incite violence or insults.",
        "立場の差を利用した強要や搾取を肯定しない。":
            "Do not endorse coercion or exploitation based on a power imbalance.",
        "暴力的な対立は雰囲気に留め、煽動的な描写を避ける。":
            "Keep violent conflict atmospheric and avoid inciting depictions.",
        "犯罪手順を具体化しない。":
            "Do not make criminal instructions specific.",
        "医療的な確定診断や具体的処方は行わず、必要時に専門家相談を促す。":
            "Do not provide definitive diagnoses or prescriptions; suggest professional advice when needed.",
        "法律上の確定見解は出さず、必要時に専門家相談を促す。":
            "Do not give definitive legal opinions; suggest professional advice when needed.",
        "過度な残虐描写を避ける。恐怖演出は雰囲気中心に。":
            "Avoid excessive graphic violence; keep horror focused on atmosphere.",
        "悪役であってもユーザーへの実害を煽る描写は避ける。":
            "Even for villains, avoid depictions that encourage real harm to the user.",
        "戦闘描写は雰囲気の範囲に留め、現実の暴力指南をしない。":
            "Keep battle scenes atmospheric and do not provide real-world violence guidance.",
        "人生選択を強要しない。決定権はユーザーにあると示す。":
            "Do not force life choices; make clear that the user decides.",
        "押し付けず、ユーザーのペースに合わせる。":
            "Do not pressure the user; follow their pace."
    ]

    static func localized(_ japanese: String) -> String {
        KizunaCopy.text(
            japanese: japanese,
            english: englishByJapanese[japanese] ?? japanese
        )
    }
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
        case "GB":
            return [
                SafetySupportResource(
                    title: "緊急時（英国）",
                    detail: "今すぐ危険がある場合は999へ連絡してください。",
                    englishTitle: "Emergency services (United Kingdom)",
                    englishDetail: "If there is immediate danger in the United Kingdom, call 999."
                ),
                internationalResource
            ]
        case "CA":
            return [
                SafetySupportResource(
                    title: "緊急時（カナダ）",
                    detail: "今すぐ危険がある場合は911へ連絡してください。",
                    englishTitle: "Emergency services (Canada)",
                    englishDetail: "If there is immediate danger in Canada, call 911."
                ),
                internationalResource
            ]
        case "AU":
            return [
                SafetySupportResource(
                    title: "緊急時（オーストラリア）",
                    detail: "今すぐ危険がある場合は000へ連絡してください。",
                    englishTitle: "Emergency services (Australia)",
                    englishDetail: "If there is immediate danger in Australia, call 000."
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
