/*
仕様:
- 役割: 安全性パイプラインで使う基本型一式 (Rating/Visibility/Action/Severity/Domain/Rule/Decision)。
- 主な型: SafetyRating, CharacterVisibility, SafetyAction, SafetySeverity, SafetyDomain,
         SafetyRule, SafetyDecision。
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
