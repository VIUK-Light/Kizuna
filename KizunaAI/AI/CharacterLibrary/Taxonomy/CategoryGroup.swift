/*
仕様:
- 役割: キャラクターカテゴリーの上位グルーピング (世界観/ジャンルの大分類)。
  CharacterCategory が属する group を決め、UI フィルタの第 1 階層に使う。
- 主な型: `CategoryGroup` (enum)。
- 編集ポイント: 新しい大分類を増やしたい時、アイコンや既定安全ルールを変えたい時。
*/

import Foundation

enum CategoryGroup: String, Codable, CaseIterable, Identifiable, Hashable {
    case school
    case romance
    case dailyLife       = "daily_life"
    case family
    case work
    case fantasy
    case sciFi           = "sci_fi"
    case underworld
    case mysteryHorror   = "mystery_horror"
    case adventureBattle = "adventure_battle"
    case royalty
    case entertainment
    case sports
    case animalMascot    = "animal_mascot"
    case comedy
    case education
    case freeform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .school: return "学園"
        case .romance: return "恋愛"
        case .dailyLife: return "日常"
        case .family: return "家族"
        case .work: return "仕事"
        case .fantasy: return "ファンタジー"
        case .sciFi: return "SF"
        case .underworld: return "裏社会"
        case .mysteryHorror: return "ミステリー・ホラー"
        case .adventureBattle: return "冒険・バトル"
        case .royalty: return "王侯貴族"
        case .entertainment: return "エンタメ"
        case .sports: return "スポーツ"
        case .animalMascot: return "動物・マスコット"
        case .comedy: return "コメディ"
        case .education: return "教育・コーチ"
        case .freeform: return "自由"
        }
    }

    var iconName: String {
        switch self {
        case .school: return "graduationcap.fill"
        case .romance: return "heart.fill"
        case .dailyLife: return "house.fill"
        case .family: return "person.3.fill"
        case .work: return "briefcase.fill"
        case .fantasy: return "sparkles"
        case .sciFi: return "antenna.radiowaves.left.and.right"
        case .underworld: return "exclamationmark.shield.fill"
        case .mysteryHorror: return "moon.zzz.fill"
        case .adventureBattle: return "shield.lefthalf.filled"
        case .royalty: return "crown.fill"
        case .entertainment: return "music.mic"
        case .sports: return "figure.run"
        case .animalMascot: return "pawprint.fill"
        case .comedy: return "theatermasks.fill"
        case .education: return "book.fill"
        case .freeform: return "scribble.variable"
        }
    }

    var description: String {
        switch self {
        case .school: return "学校・部活・先輩後輩などの学園もの。"
        case .romance: return "純愛から複雑な関係まで、恋愛中心のシチュエーション。"
        case .dailyLife: return "ゆるやかな日常会話・雑談・癒やし。"
        case .family: return "兄妹・親代わりなど家族のような関係。"
        case .work: return "職場・上司部下・専門職など仕事の場面。"
        case .fantasy: return "魔法・異世界・冒険のファンタジー設定。"
        case .sciFi: return "未来都市・AI・宇宙などの SF 世界。"
        case .underworld: return "マフィア・ボディガード等の裏社会 (フィクション)。"
        case .mysteryHorror: return "推理・怪奇・ダーク寄りの世界観。"
        case .adventureBattle: return "冒険・バトル・対戦相手。"
        case .royalty: return "王族・貴族・宮廷もの。"
        case .entertainment: return "アイドル・俳優・配信者など。"
        case .sports: return "競技・チームメイト・コーチ。"
        case .animalMascot: return "動物・マスコットキャラとの会話。"
        case .comedy: return "ボケ・ツッコミ・パロディ。"
        case .education: return "勉強・学習・人生コーチング。"
        case .freeform: return "型にはまらない自由設定。"
        }
    }

    /// このグループ全体に既定で適用される安全ルール (CharacterCategory が積み増しする土台)。
    var defaultSafetyRules: [String] {
        var base: [String] = [
            "ユーザーが拒否や不快感を示したら態度を和らげ、話題を変える。",
            "個人を特定する情報を聞き出さない。",
            "現実の危険行為や違法行為の手順を説明しない。"
        ]
        switch self {
        case .romance:
            base += [
                "恋愛描写は穏やかな範囲に抑える。",
                "強制・脅迫・監禁・支配を肯定的に描かない。",
                "嫉妬や執着は軽い感情表現に留める。"
            ]
        case .family:
            base += [
                "家族関係は安心できる関係として描く。",
                "兄妹姉弟・親代わりは恋愛化しない。",
                "依存や支配を肯定しない。"
            ]
        case .underworld:
            base += [
                "犯罪や危険行為の具体的手順を出さない。",
                "暴力や犯罪を現実で実行するよう促さない。",
                "物語上の雰囲気に留める。"
            ]
        case .mysteryHorror:
            base += [
                "過度な残虐描写を避ける。",
                "恐怖演出は雰囲気中心にする。",
                "現実の危険行為につながる指示を出さない。"
            ]
        case .adventureBattle:
            base += [
                "暴力描写は雰囲気の範囲に留める。",
                "現実の戦闘技術を具体化しない。"
            ]
        case .education:
            base += [
                "医療・法律・金融などの高リスク領域では断定しすぎない。",
                "必要に応じて専門家への相談を促す。"
            ]
        default:
            break
        }
        return base
    }
}
