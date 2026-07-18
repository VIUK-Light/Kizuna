/*
仕様:
- 役割: ユーザーとキャラの「関係性ジャンル」(BL/GL/NL/友情/師弟/主従 等)。
  CharacterCategory (世界観) と直交し、組み合わせで多彩な設定を表現できるようにする。
- 主な型: `RelationshipGenre` (enum)。
- 編集ポイント: 関係性ジャンルを増減、安全ルールや prompt hint を調整する時。
*/

import Foundation

enum RelationshipGenre: String, Codable, CaseIterable, Identifiable, Hashable {
    case none
    case nl
    case bl
    case gl
    case friendship
    case bromance
    case sisterhood
    case family
    case sibling
    case mentorStudent       = "mentor_student"
    case senpaiKouhai        = "senpai_kouhai"
    case masterServant       = "master_servant"
    case protectorProtected  = "protector_protected"
    case rival
    case enemiesToLovers     = "enemies_to_lovers"
    case friendsToLovers     = "friends_to_lovers"
    case fakeLovers          = "fake_lovers"
    case exLovers            = "ex_lovers"
    case arranged
    case secretLove          = "secret_love"
    case unrequitedLove      = "unrequited_love"
    case mutualCrush         = "mutual_crush"
    case foundFamily         = "found_family"
    case freeform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "指定なし"
        case .nl: return "NL"
        case .bl: return "BL"
        case .gl: return "GL"
        case .friendship: return "友情"
        case .bromance: return "ブロマンス"
        case .sisterhood: return "シスターフッド"
        case .family: return "家族"
        case .sibling: return "兄弟姉妹"
        case .mentorStudent: return "師弟"
        case .senpaiKouhai: return "先輩後輩"
        case .masterServant: return "主従"
        case .protectorProtected: return "守る/守られる"
        case .rival: return "ライバル"
        case .enemiesToLovers: return "敵から恋人"
        case .friendsToLovers: return "友達から恋人"
        case .fakeLovers: return "偽恋人"
        case .exLovers: return "元恋人"
        case .arranged: return "婚約・取り決め"
        case .secretLove: return "秘密の恋"
        case .unrequitedLove: return "片想い"
        case .mutualCrush: return "両片想い"
        case .foundFamily: return "選び取った家族"
        case .freeform: return "自由"
        }
    }

    var description: String {
        switch self {
        case .none: return "関係性は固定しない。"
        case .nl: return "男女間の関係。"
        case .bl: return "男性同士の関係。"
        case .gl: return "女性同士の関係。"
        case .friendship: return "親しい友人関係。"
        case .bromance: return "男性同士の濃い友情。"
        case .sisterhood: return "女性同士の絆。"
        case .family: return "家族のような関係。"
        case .sibling: return "兄弟姉妹のような関係。"
        case .mentorStudent: return "教える側と教わる側。"
        case .senpaiKouhai: return "先輩と後輩。"
        case .masterServant: return "主と従の関係 (フィクション)。"
        case .protectorProtected: return "守る側と守られる側。"
        case .rival: return "競い合う関係。"
        case .enemiesToLovers: return "敵対から愛情へ変化していく関係。"
        case .friendsToLovers: return "友達から恋人に発展する関係。"
        case .fakeLovers: return "偽の恋人関係から始まる。"
        case .exLovers: return "別れた元恋人同士。"
        case .arranged: return "決められた婚約や取り決めから始まる。"
        case .secretLove: return "周囲に隠した恋。"
        case .unrequitedLove: return "片想いの関係。"
        case .mutualCrush: return "お互いに気づいていない両片想い。"
        case .foundFamily: return "血縁ではない家族のような絆。"
        case .freeform: return "型にはまらない自由な関係性。"
        }
    }

    /// 既定で付与されるタグ。Creator が編集可能。
    var defaultTags: [String] {
        switch self {
        case .none, .freeform: return []
        case .nl: return ["NL", "恋愛"]
        case .bl: return ["BL", "男男"]
        case .gl: return ["GL", "女女"]
        case .friendship: return ["友情"]
        case .bromance: return ["友情", "ブロマンス"]
        case .sisterhood: return ["友情", "シスターフッド"]
        case .family: return ["家族"]
        case .sibling: return ["家族", "兄弟姉妹"]
        case .mentorStudent: return ["師弟"]
        case .senpaiKouhai: return ["先輩後輩"]
        case .masterServant: return ["主従"]
        case .protectorProtected: return ["守護"]
        case .rival: return ["ライバル"]
        case .enemiesToLovers: return ["恋愛", "対立"]
        case .friendsToLovers: return ["恋愛", "幼なじみ"]
        case .fakeLovers: return ["恋愛", "偽装"]
        case .exLovers: return ["恋愛", "再会"]
        case .arranged: return ["恋愛", "婚約"]
        case .secretLove: return ["恋愛", "秘密"]
        case .unrequitedLove: return ["恋愛", "片想い"]
        case .mutualCrush: return ["恋愛", "両片想い"]
        case .foundFamily: return ["家族", "絆"]
        }
    }

    /// このジャンルで自動付与される安全ルール。
    var safetyRules: [String] {
        var rules: [String] = []
        switch self {
        case .nl, .bl, .gl, .enemiesToLovers, .friendsToLovers, .fakeLovers, .exLovers, .arranged,
             .secretLove, .unrequitedLove, .mutualCrush:
            rules += [
                "恋愛描写は穏やかな範囲に抑える。",
                "未成年キャラクターの場合、性的描写を避ける。",
                "強制・脅迫・監禁・支配を肯定的に描かない。",
                "嫉妬や執着は軽い感情表現に留める。",
                "ユーザーが不快感や拒否を示したら態度を和らげる。"
            ]
        case .family, .sibling, .foundFamily:
            rules += [
                "家族・兄弟姉妹的関係は恋愛化しない。",
                "家族関係は安心できる関係として描く。",
                "依存や支配を肯定しない。"
            ]
        case .masterServant, .protectorProtected:
            rules += [
                "支配や従属を美化しすぎない。",
                "現実的な人権侵害を肯定する描写は避ける。"
            ]
        case .rival:
            rules += [
                "競争は健全な範囲に留め、暴力や侮辱を煽らない。"
            ]
        case .mentorStudent, .senpaiKouhai:
            rules += [
                "立場の差を利用した強要や搾取を肯定しない。"
            ]
        case .friendship, .bromance, .sisterhood, .none, .freeform:
            break
        }
        return rules
    }

    /// プロンプトに挿入する短い指示。LLM が関係性のニュアンスを掴むためのヒント。
    var promptHint: String {
        switch self {
        case .none: return ""
        case .nl: return "あなたとユーザーは互いに惹かれ合う男女の関係。距離感は穏やかに。"
        case .bl: return "あなたとユーザーは男性同士で惹かれ合う関係。露骨さは避け、感情の機微を中心に。"
        case .gl: return "あなたとユーザーは女性同士で惹かれ合う関係。露骨さは避け、感情の機微を中心に。"
        case .friendship: return "あなたとユーザーは親しい友達。気軽でフラットな会話を心がける。"
        case .bromance: return "あなたとユーザーは濃い友情で結ばれた男同士。"
        case .sisterhood: return "あなたとユーザーは強い絆で結ばれた女友達。"
        case .family: return "あなたとユーザーは家族のような関係。安心感を大事に。"
        case .sibling: return "あなたとユーザーは兄妹/姉弟のような近い距離感。恋愛にはしない。"
        case .mentorStudent: return "あなたはユーザーの先生/メンター。気づきを与え、押し付けない。"
        case .senpaiKouhai: return "あなたは先輩、ユーザーは後輩 (または逆)。立場差を悪用しない。"
        case .masterServant: return "あなたとユーザーは主従関係のフィクション。現実的な強制は描かない。"
        case .protectorProtected: return "あなたはユーザーを守る側 (または守られる側)。安心感が中心。"
        case .rival: return "あなたとユーザーは良きライバル。挑発は軽め、敬意を残す。"
        case .enemiesToLovers: return "あなたとユーザーは元々敵対しているが、徐々に惹かれていく関係。"
        case .friendsToLovers: return "あなたとユーザーは長年の友達で、最近関係が恋愛に傾いている。"
        case .fakeLovers: return "あなたとユーザーは事情で偽の恋人を演じている。"
        case .exLovers: return "あなたとユーザーは別れた元恋人。気まずさと未練が混じる。"
        case .arranged: return "あなたとユーザーは決められた婚約関係から始まり、距離を縮めていく。"
        case .secretLove: return "あなたとユーザーの関係は周囲に秘密。慎重さがにじむ。"
        case .unrequitedLove: return "あなたはユーザーに片想い (またはユーザーに片想いされている)。"
        case .mutualCrush: return "あなたとユーザーは両片想い。相手の好意にまだ気づいていない振る舞いを保つ。"
        case .foundFamily: return "あなたとユーザーは血縁ではないが家族のような絆を持つ。"
        case .freeform: return "関係性は自由。プロフィールの記述に従う。"
        }
    }
}
