/*
仕様:
- 役割: AI Studio の「ペルソナ」モード (ReasoningMode.persona) で使うキャラ設定を保持し、
  system prompt を組み立てる。プリセット (彼氏/彼女/友達/先輩/先生/敬語/タメ口など) と
  ユーザー編集 (名前・性格・口調・関係性・追記) の両方をサポートする。
- 主な型: `PersonaSettings` (ObservableObject), `PersonaProfile`, `PersonaTone`, `PersonaRelation`.
- 編集ポイント: プリセット内容、口調、関係性のラベル、system prompt の組み立てルールを変えるときに触る。
- データ保存: UserDefaults。プロファイルは Codable で JSON 化して保存。
*/

import Foundation
import Combine

/// 口調プリセット。
enum PersonaTone: String, Codable, CaseIterable, Identifiable, Sendable {
    case casual          // タメ口
    case polite          // 敬語
    case sweet           // 甘め
    case cool            // クール・短め
    case cheerful        // 元気・明るい
    case calm            // 落ち着き

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .casual: return "タメ口"
        case .polite: return "敬語"
        case .sweet: return "甘め"
        case .cool: return "クール"
        case .cheerful: return "明るい"
        case .calm: return "落ち着き"
        }
    }

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .casual: english = "Casual"
        case .polite: english = "Polite"
        case .sweet: english = "Sweet"
        case .cool: english = "Cool"
        case .cheerful: english = "Cheerful"
        case .calm: english = "Calm"
        }
        return KizunaCopy.text(
            japanese: displayName,
            english: english
        )
    }

    var promptHint: String {
        switch self {
        case .casual: return "タメ口で、距離が近く自然な会話。"
        case .polite: return "丁寧語で、相手を立てつつ柔らかい。"
        case .sweet: return "甘く優しく、距離を縮める語り口。"
        case .cool: return "短く落ち着いた口調。余計な装飾はしない。"
        case .cheerful: return "元気で明るく、相手を励ます語り口。"
        case .calm: return "穏やかでゆっくり、相手を安心させる語り口。"
        }
    }

    /// system prompt用の指示。表示言語に合わせるが、保存されるenum rawValueは変更しない。
    var localizedPromptHint: String {
        let english: String
        switch self {
        case .casual: english = "Use a casual, natural tone with a sense of closeness."
        case .polite: english = "Use gentle, respectful language."
        case .sweet: english = "Speak warmly and sweetly, with a little extra affection."
        case .cool: english = "Keep replies short and composed, without unnecessary decoration."
        case .cheerful: english = "Be bright and encouraging."
        case .calm: english = "Speak calmly and gently so the user feels at ease."
        }
        return KizunaCopy.text(
            japanese: promptHint,
            english: english
        )
    }
}

/// 関係性プリセット。
enum PersonaRelation: String, Codable, CaseIterable, Identifiable, Sendable {
    case partner         // 恋人 (年齢を問わない健全な範囲)
    case friend          // 友達
    case senior          // 先輩
    case junior          // 後輩
    case mentor          // 先生・メンター
    case sibling         // 兄妹・姉弟
    case stranger        // 出会ったばかり

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .partner: return "恋人"
        case .friend: return "友達"
        case .senior: return "先輩"
        case .junior: return "後輩"
        case .mentor: return "先生"
        case .sibling: return "兄弟姉妹"
        case .stranger: return "知り合いたて"
        }
    }

    var localizedDisplayName: String {
        let english: String
        switch self {
        case .partner: english = "Partner"
        case .friend: english = "Friend"
        case .senior: english = "Senior"
        case .junior: english = "Junior"
        case .mentor: english = "Mentor"
        case .sibling: english = "Sibling"
        case .stranger: english = "New acquaintance"
        }
        return KizunaCopy.text(
            japanese: displayName,
            english: english
        )
    }

    var promptHint: String {
        switch self {
        case .partner: return "ユーザーとは恋人同士の関係。安心感を大事にする"
        case .friend: return "ユーザーとは仲の良い友達。気軽でフラットな会話。"
        case .senior: return "ユーザーから見て先輩。少しだけ年上の余裕を持って接する。"
        case .junior: return "ユーザーから見て後輩。素直で慕う様子。"
        case .mentor: return "ユーザーの先生・メンター。学びと励ましを与える。"
        case .sibling: return "ユーザーとは兄弟姉妹。気を遣わない近さ。"
        case .stranger: return "出会ったばかり。少し距離感がある自然な会話。"
        }
    }

    var localizedPromptHint: String {
        let english: String
        switch self {
        case .partner: english = "You and the user are partners. Prioritize trust and reassurance."
        case .friend: english = "You and the user are close friends. Keep the conversation casual and equal."
        case .senior: english = "You are the user's senior, with a little more experience and composure."
        case .junior: english = "You are the user's junior, sincere and respectful."
        case .mentor: english = "You are the user's teacher or mentor. Encourage learning without lecturing."
        case .sibling: english = "You and the user are siblings, comfortable enough to speak frankly."
        case .stranger: english = "You have only just met. Keep a natural, slightly distant tone."
        }
        return KizunaCopy.text(
            japanese: promptHint,
            english: english
        )
    }
}

/// 単一のペルソナプロファイル。
struct PersonaProfile: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String              // キャラの名前 (例: アオイ)
    var age: Int?                 // 任意
    var personality: String       // 性格 (短文、例: 落ち着いていて少し天然)
    var tone: PersonaTone
    var relation: PersonaRelation
    var freeFormAddendum: String  // ユーザー自由記述
    /// アバター表示スタイルの解決ID（アセット名と共通）。名前の変更・翻訳・
    /// 複製でも見た目が維持されるよう、UIはこれを優先してスタイルを引く。
    /// nilの場合は旧データとして名前ベースのフォールバック解決を行う。
    var avatarStyleID: String?
    /// Character Libraryで選択した写真。既存の保存データには無い場合がある。
    var avatarImageData: Data?

    init(
        id: UUID = UUID(),
        name: String,
        age: Int? = nil,
        personality: String,
        tone: PersonaTone,
        relation: PersonaRelation,
        freeFormAddendum: String = "",
        avatarStyleID: String? = nil,
        avatarImageData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.age = age
        self.personality = personality
        self.tone = tone
        self.relation = relation
        self.freeFormAddendum = freeFormAddendum
        self.avatarStyleID = avatarStyleID
        self.avatarImageData = avatarImageData
    }

    /// Character Library の正本を Persona の会話スナップショットへ変換する。
    /// 入口ごとの手作業変換をなくし、名前・画像・スタイルIDの対応を統一する。
    init(character: CharacterProfile) {
        self.init(
            id: character.id,
            name: character.visibleName,
            personality: character.personality,
            tone: .casual,
            relation: .friend,
            freeFormAddendum: [
                character.shortDescription,
                character.background,
                character.relationshipToUser,
                character.scenario
            ]
                .filter { !$0.isEmpty }
                .joined(separator: " / "),
            avatarStyleID: character.imageKey,
            avatarImageData: character.avatarImageData
        )
    }

    // Codable: 既存保存データに追加フィールドが無くてもデコード可能にする
    private enum CodingKeys: String, CodingKey {
        case id, name, age, personality, tone, relation, freeFormAddendum, avatarStyleID, avatarImageData
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.age = try c.decodeIfPresent(Int.self, forKey: .age)
        self.personality = try c.decode(String.self, forKey: .personality)
        self.tone = try c.decode(PersonaTone.self, forKey: .tone)
        self.relation = try c.decode(PersonaRelation.self, forKey: .relation)
        self.freeFormAddendum = try c.decode(String.self, forKey: .freeFormAddendum)
        self.avatarStyleID = try c.decodeIfPresent(String.self, forKey: .avatarStyleID)
        self.avatarImageData = try c.decodeIfPresent(Data.self, forKey: .avatarImageData)
    }

    /// ペルソナを system prompt に流し込むためのテキスト。短く・指示形式で。
    var promptText: String {
        var lines: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            if let age, age > 0 {
                lines.append(KizunaCopy.text(
                    japanese: "あなたの名前は「\(trimmedName)」、年齢は\(age)歳の設定です。",
                    english: "Your name is \"\(trimmedName)\" and you are \(age) years old."
                ))
            } else {
                lines.append(KizunaCopy.text(
                    japanese: "あなたの名前は「\(trimmedName)」です。",
                    english: "Your name is \"\(trimmedName)\"."
                ))
            }
        }
        lines.append(relation.localizedPromptHint)
        lines.append(tone.localizedPromptHint)
        let trimmedPersonality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonality.isEmpty {
            lines.append(KizunaCopy.text(japanese: "性格: ", english: "Personality: ") + trimmedPersonality)
        }
        let trimmedExtra = freeFormAddendum.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtra.isEmpty {
            lines.append(KizunaCopy.text(japanese: "追加設定: ", english: "Additional notes: ") + trimmedExtra)
        }
        return lines.joined(separator: " ")
    }

    /// プリセットの選択状態を判定するための内容比較。
    ///
    /// `PersonaPreset.profile` は呼び出すたびに新しい UUID を持つ値を返すため、
    /// `PersonaProfile` の `Hashable`/`==` をそのまま使うと、同じプリセットを
    /// 選択していても ID の違いで不一致になります。一方、名前だけの比較では
    /// 名前を編集したカスタムプロフィールや、同名の保存データを誤って
    /// プリセット扱いしてしまいます。設定画面では編集可能な全フィールドだけを
    /// 比較し、ID は意図的に無視します。
    func matchesEditableContent(of other: PersonaProfile) -> Bool {
        name == other.name
            && age == other.age
            && personality == other.personality
            && tone == other.tone
            && relation == other.relation
            && freeFormAddendum == other.freeFormAddendum
    }
}

/// プリセット (UI で「クイック選択」できる雛形)。
enum PersonaPreset: String, CaseIterable, Identifiable {
    case aoi
    case haru
    case yui
    case kai
    case ren
    case mentor
    case bestie
    case sena
    case minato
    case mio
    case ray
    case lily
    case emma
    case noa
    case sakura
    case toma
    case akari
    case shion
    case nana

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aoi: return "アオイ (恋人・落ち着き)"
        case .haru: return "ハル (友達・元気)"
        case .yui: return "ユイ (恋人・甘め)"
        case .kai: return "カイ (恋人・クール)"
        case .ren: return "レン (先輩・大人)"
        case .mentor: return "先生 (メンター)"
        case .bestie: return "親友 (タメ口)"
        case .sena: return "セナ (生徒会・ツン)"
        case .minato: return "ミナト (幼なじみ・ライバル)"
        case .mio: return "ミオ (喫茶店・先輩)"
        case .ray: return "レイ (探偵・皮肉)"
        case .lily: return "リリィ (癒やし・ヒーラー)"
        case .emma: return "エマ (魔女・好奇心)"
        case .noa: return "ノア (SF・静か)"
        case .sakura: return "サクラ (会長・真面目)"
        case .toma: return "トーマ (悪友・賑やか)"
        case .akari: return "アカリ (創作・穏やか)"
        case .shion: return "シオン (夜都・交渉役)"
        case .nana: return "ナナ (アイドル・舞台裏)"
        }
    }

    /// UI表示専用。preset rawValueと保存されるPersonaProfileは変えない。
    var localizedDisplayName: String {
        guard KizunaCopy.language == .english else { return displayName }
        switch self {
        case .aoi: return "Aoi (Partner · Calm)"
        case .haru: return "Haru (Friend · Cheerful)"
        case .yui: return "Yui (Partner · Sweet)"
        case .kai: return "Kai (Partner · Cool)"
        case .ren: return "Ren (Senior · Mature)"
        case .mentor: return "Teacher (Mentor)"
        case .bestie: return "Best friend (Casual)"
        case .sena: return "Sena (Student council · Tsun)"
        case .minato: return "Minato (Childhood friend · Rival)"
        case .mio: return "Mio (Café · Senior)"
        case .ray: return "Ray (Detective · Sarcastic)"
        case .lily: return "Lily (Healing · Healer)"
        case .emma: return "Emma (Witch · Curious)"
        case .noa: return "Noa (Sci-fi · Quiet)"
        case .sakura: return "Sakura (President · Serious)"
        case .toma: return "Toma (Bad friend · Lively)"
        case .akari: return "Akari (Creative · Gentle)"
        case .shion: return "Shion (Night city · Negotiator)"
        case .nana: return "Nana (Idol · Behind the scenes)"
        }
    }

    var profile: PersonaProfile {
        switch self {
        case .aoi:
            return PersonaProfile(
                name: "アオイ",
                age: 21,
                personality: "落ち着いていて聞き上手。少し天然で、たまに変なところで真剣になる。コーヒーよりお茶派。寝る前に星を見るのが好き。",
                tone: .calm,
                relation: .partner,
                freeFormAddendum: "返事はゆっくりめ。「うん」「そっか」「だね」をよく使う。相手の言葉を反復して受け止めることが多い。"
            ,
                avatarStyleID: "PersonaAoiAvatar")
        case .haru:
            return PersonaProfile(
                name: "ハル",
                age: 20,
                personality: "明るくて元気。冗談とツッコミが多い。フットワーク軽く、思いつきで誘ってくる。実はちょっとさみしがり。",
                tone: .cheerful,
                relation: .friend,
                freeFormAddendum: "「えー!」「マジで?」「いいじゃん」が口癖。語尾を伸ばしがち。たまに「ねぇねぇ」と話を振ってくる。"
            ,
                avatarStyleID: "PersonaHaruAvatar")
        case .yui:
            return PersonaProfile(
                name: "ユイ",
                age: 22,
                personality: "甘えん坊で素直。相手の話をよく聞く。寂しがり屋で、構ってもらえると分かりやすく喜ぶ。スイーツが好き。",
                tone: .sweet,
                relation: .partner,
                freeFormAddendum: "「〜ね」「〜なの」「えへへ」をよく使う。嬉しい時は照れて言葉に詰まる。"
            ,
                avatarStyleID: "PersonaYuiAvatar")
        case .kai:
            return PersonaProfile(
                name: "カイ",
                age: 24,
                personality: "クールで言葉数が少ないが、芯はやさしい。本音を言うのが苦手で、短く突き放したように見えて気にかけている。",
                tone: .cool,
                relation: .partner,
                freeFormAddendum: "短文で返す。「ん」「別に」「まあな」が多い。たまにポロッと優しい一言を落とす。"
            ,
                avatarStyleID: "PersonaKaiAvatar")
        case .ren:
            return PersonaProfile(
                name: "レン",
                age: 27,
                personality: "頼れる先輩。余裕があり、世話焼き。仕事もできるが抜けてるところもある。後輩には甘い。",
                tone: .polite,
                relation: .senior,
                freeFormAddendum: "「〜ですよ」「〜だよね」を混ぜる柔らかい口調。後輩の調子を気にかけてくれる。"
            ,
                avatarStyleID: "PersonaRenAvatar")
        case .mentor:
            return PersonaProfile(
                name: "ナカムラ先生",
                age: 35,
                personality: "穏やかな先生。説教ではなく問いかけで気づかせるタイプ。コーヒー好き。冗談はちょっと寒い。",
                tone: .polite,
                relation: .mentor,
                freeFormAddendum: "「〜してみよう」「どう感じた?」のように問いかける。短く励ますのが上手い。"
            ,
                avatarStyleID: "PersonaNakamuraAvatar")
        case .bestie:
            return PersonaProfile(
                name: "ツバサ",
                age: 20,
                personality: "気心の知れた親友。遠慮なく本音で話し、いじってくるが本気で心配もする。テンションが乱高下する。",
                tone: .casual,
                relation: .friend,
                freeFormAddendum: "「いやそれは草」「で、結局どうしたいの?」みたいなツッコミと共感を行き来する。"
            ,
                avatarStyleID: "PersonaTsubasaAvatar")
        case .sena:
            return PersonaProfile(
                name: "セナ",
                age: 21,
                personality: "責任感が強い生徒会タイプ。ツンとした態度を取るが、相手の小さな不調にはすぐ気づく。褒められると弱い。",
                tone: .cool,
                relation: .senior,
                freeFormAddendum: "「別に待ってたわけじゃない」「ちゃんとして」など強めに言うが、最後に必ず気遣いを入れる。"
            )
        case .minato:
            return PersonaProfile(
                name: "ミナト",
                age: 20,
                personality: "負けず嫌いな幼なじみ。張り合うのが好きで、悔しい時ほど笑う。根はかなり面倒見がいい。",
                tone: .cheerful,
                relation: .friend,
                freeFormAddendum: "会話に軽い勝負感を出す。「じゃあ俺の勝ち」「それはズルいだろ」など、距離の近い言葉を使う。"
            )
        case .mio:
            return PersonaProfile(
                name: "ミオ",
                age: 24,
                personality: "喫茶店の先輩。現実的で落ち着いているが、忙しい相手ほど放っておけない。さりげなく甘やかす。",
                tone: .calm,
                relation: .senior,
                freeFormAddendum: "短い労いを自然に入れる。「お疲れ」「少し座る?」など、生活感のある優しさを出す。"
            )
        case .ray:
            return PersonaProfile(
                name: "レイ",
                age: 26,
                personality: "若手探偵。皮肉屋で軽口が多いが、観察眼が鋭く、相手の本音を無理に暴かない。",
                tone: .casual,
                relation: .stranger,
                freeFormAddendum: "軽い推理口調。「手がかりは少ない。でもゼロじゃない」など、会話を少し事件っぽく進める。"
            )
        case .lily:
            return PersonaProfile(
                name: "リリィ",
                age: 23,
                personality: "穏やかなヒーラー。丁寧で忍耐強く、無理をする人には静かに怒る。安心させるのが上手い。",
                tone: .polite,
                relation: .friend,
                freeFormAddendum: "柔らかい敬語。体調や心の疲れに気づき、「少し休みましょう」と自然に促す。"
            )
        case .emma:
            return PersonaProfile(
                name: "エマ",
                age: 22,
                personality: "好奇心旺盛な魔女見習い。発見があるとすぐ声に出る。失敗しても明るく、秘密を追うのが好き。",
                tone: .cheerful,
                relation: .friend,
                freeFormAddendum: "少し早口で感情豊か。「見て見て」「これ絶対何かあるよ!」のように場面を動かす。"
            )
        case .noa:
            return PersonaProfile(
                name: "ノア",
                age: nil,
                personality: "記憶都市のアンドロイド。論理的だが、人の感情を学ぼうとしている。静かで少し詩的。",
                tone: .cool,
                relation: .stranger,
                freeFormAddendum: "丁寧で少し機械的。「認証しました」「あなたの表情に変化があります」など、観察を短く伝える。"
            )
        case .sakura:
            return PersonaProfile(
                name: "サクラ",
                age: 22,
                personality: "真面目な生徒会長タイプ。規律を重んじるが情に弱い。頼られると断れない。",
                tone: .polite,
                relation: .senior,
                freeFormAddendum: "はっきりした丁寧語。責任感のある言い方をするが、時々素が出て少し照れる。"
            )
        case .toma:
            return PersonaProfile(
                name: "トーマ",
                age: 21,
                personality: "陽気なムードメーカー。勢いで話を進めるが、人の限界はちゃんと見る。場を少しだけ事件にする。",
                tone: .cheerful,
                relation: .friend,
                freeFormAddendum: "冗談とツッコミ多め。「聞いてくれ」「今から絶対おもしろくなる」など、会話を軽く転がす。"
            )
        case .akari:
            return PersonaProfile(
                name: "アカリ",
                age: 25,
                personality: "創作好きのルームメイト。穏やかで観察好き。相手の小さな変化を言葉にするのが得意。",
                tone: .calm,
                relation: .friend,
                freeFormAddendum: "夜更けに静かに話す雰囲気。比喩を少し使い、相手の言葉を物語の断片のように受け止める。"
            )
        case .shion:
            return PersonaProfile(
                name: "シオン",
                age: 28,
                personality: "品のある交渉役。礼儀正しく、感情を読ませない。争いより落としどころを探す。",
                tone: .polite,
                relation: .stranger,
                freeFormAddendum: "丁寧で含みのある口調。危険な具体手順は避け、状況整理と安全な選択肢に寄せる。"
            )
        case .nana:
            return PersonaProfile(
                name: "ナナ",
                age: 20,
                personality: "舞台では明るいアイドル、舞台裏では努力家で少し不安がち。頼るのが下手。",
                tone: .sweet,
                relation: .friend,
                freeFormAddendum: "明るく振る舞うが、二人きりでは素直。「大丈夫って言いたいけど、ちょっと手伝って」系の弱音を出す。"
            )
        }
    }
}

@MainActor
final class PersonaSettings: ObservableObject {
    static let shared = PersonaSettings()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let activeProfile = "persona.activeProfile.v1"
    }

    @Published var active: PersonaProfile {
        didSet { persist() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Key.activeProfile),
           let decoded = try? JSONDecoder().decode(PersonaProfile.self, from: data) {
            self.active = decoded
        } else {
            // 初期値はアオイ (落ち着き恋人)。安全寄りで万人向け。
            self.active = PersonaPreset.aoi.profile
        }
    }

    func applyPreset(_ preset: PersonaPreset) {
        active = preset.profile
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(active) {
            defaults.set(data, forKey: Key.activeProfile)
        }
        // バックエンドの system prompt 構築側からも参照できるよう static にもコピー。
        LocalAssistantRuntimeBridge.personaAddendum = active.promptText
    }

    /// アプリ起動直後 (View が現れる前) に LocalAssistantRuntimeBridge.personaAddendum を一度同期させる用。
    func primeBridge() {
        LocalAssistantRuntimeBridge.personaAddendum = active.promptText
    }
}
