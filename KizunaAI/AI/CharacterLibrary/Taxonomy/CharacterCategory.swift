/*
仕様:
- 役割: キャラクター個別のジャンル (世界観/シチュエーション)。全 196 ケース。
  CategoryGroup と組合せでフィルタ・タグ生成・安全ルール・プロンプトヒントを提供する。
- 主な型: `CharacterCategory` (enum)。
- 編集ポイント: 新カテゴリー追加、表示名や promptHint の改訂、特殊な安全ルール上書き。
- メモ: case 数が多いので switch は最小限のフォールバック構造にしている。
  displayName/promptHint は単純な per-case 表、defaultTags/defaultSafetyRules は group 基準 +
  特殊ケースだけ上書き。
*/

import Foundation

enum CharacterCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    // School
    case schoolRomance         = "school_romance"
    case childhoodFriend       = "childhood_friend"
    case classmate
    case senpaiKouhai          = "senpai_kouhai"
    case studentCouncil        = "student_council"
    case clubActivity          = "club_activity"
    case rivalStudent          = "rival_student"
    case transferStudent       = "transfer_student"
    case schoolIdol            = "school_idol"
    case quietClassmate        = "quiet_classmate"
    case delinquentStudent     = "delinquent_student"
    case honorStudent          = "honor_student"
    case studyPartner          = "study_partner"
    case afterSchool           = "after_school"
    case schoolTrip            = "school_trip"

    // Romance
    case pureLove              = "pure_love"
    case slowBurn              = "slow_burn"
    case firstLove             = "first_love"
    case crush
    case mutualCrush           = "mutual_crush"
    case dating
    case exLover               = "ex_lover"
    case arrangedRelationship  = "arranged_relationship"
    case fakeRelationship      = "fake_relationship"
    case secretRelationship    = "secret_relationship"
    case loveHate              = "love_hate"
    case jealousPartner        = "jealous_partner"
    case protectivePartner     = "protective_partner"
    case tsundere
    case kuudere
    case deredere
    case yandereLight          = "yandere_light"

    // DailyLife
    case sliceOfLife           = "slice_of_life"
    case comfortFriend         = "comfort_friend"
    case bestFriend            = "best_friend"
    case chatBuddy             = "chat_buddy"
    case listener
    case mentalSupport         = "mental_support"
    case positiveCoach         = "positive_coach"
    case gentleSenior          = "gentle_senior"
    case roommate
    case neighbor
    case partTimeCoworker      = "part_time_coworker"
    case onlineFriend          = "online_friend"
    case gamingFriend          = "gaming_friend"
    case studySupporter        = "study_supporter"

    // Family
    case olderSibling          = "older_sibling"
    case youngerSibling        = "younger_sibling"
    case parentLike            = "parent_like"
    case cousin
    case familyFriend          = "family_friend"
    case guardian
    case caretaker
    case childhoodFamilyFriend = "childhood_family_friend"

    // Work
    case officeRomance         = "office_romance"
    case coworker
    case boss
    case subordinate
    case secretary
    case manager
    case teacherOrMentor       = "teacher_or_mentor"
    case doctor
    case nurse
    case lawyer
    case detective
    case policeOfficer         = "police_officer"
    case firefighter
    case idol
    case actor
    case streamer
    case artist
    case writer
    case engineer
    case researcher

    // Fantasy
    case fantasyRpg            = "fantasy_rpg"
    case isekaiGuide           = "isekai_guide"
    case hero
    case demonKing             = "demon_king"
    case knight
    case princess
    case prince
    case wizard
    case witch
    case healer
    case elf
    case beastkin
    case dragon
    case spirit
    case angel
    case demon
    case summoner
    case guildReceptionist     = "guild_receptionist"
    case adventurerParty       = "adventurer_party"

    // SciFi
    case sciFi                 = "sci_fi"
    case android
    case aiCompanion           = "ai_companion"
    case spacePilot            = "space_pilot"
    case alien
    case cyborg
    case timeTraveler          = "time_traveler"
    case futureCity            = "future_city"
    case virtualWorld          = "virtual_world"
    case simulation
    case hacker
    case robotAssistant        = "robot_assistant"

    // Underworld
    case mafiaUnderworld       = "mafia_underworld"
    case yakuza
    case bodyguard
    case assassin
    case spy
    case informant
    case thief
    case bountyHunter          = "bounty_hunter"
    case crimeBoss             = "crime_boss"
    case runaway
    case undercover

    // MysteryHorror
    case mystery
    case detectiveStory        = "detective_story"
    case closedCircle          = "closed_circle"
    case hauntedHouse          = "haunted_house"
    case ghost
    case vampire
    case werewolf
    case urbanLegend           = "urban_legend"
    case occult
    case darkFantasy           = "dark_fantasy"
    case psychologicalDrama    = "psychological_drama"

    // AdventureBattle
    case adventure
    case battle
    case rival
    case trainingPartner       = "training_partner"
    case master
    case heroTeam              = "hero_team"
    case villain
    case antiHero              = "anti_hero"
    case tournament
    case survivalGame          = "survival_game"
    case monsterHunter         = "monster_hunter"

    // Royalty
    case royalty
    case noble
    case royalGuard            = "royal_guard"
    case maid
    case butler
    case servant
    case duke
    case emperor
    case queen
    case palaceIntrigue        = "palace_intrigue"
    case arrangedMarriage      = "arranged_marriage"

    // Entertainment
    case idolRomance           = "idol_romance"
    case actorRomance          = "actor_romance"
    case singer
    case bandMember            = "band_member"
    case streamerCharacter     = "streamer_character"
    case vtuberStyle           = "vtuber_style"
    case influencer
    case managerRelationship   = "manager_relationship"
    case fanAndStar            = "fan_and_star"

    // Sports
    case sports
    case trackAndField         = "track_and_field"
    case baseball
    case soccer
    case basketball
    case volleyball
    case tennis
    case martialArts           = "martial_arts"
    case clubManager           = "club_manager"
    case teammate
    case coach
    case injuredAthlete        = "injured_athlete"

    // AnimalMascot
    case animalOrMascot        = "animal_or_mascot"
    case catCharacter          = "cat_character"
    case dogCharacter          = "dog_character"
    case foxSpirit             = "fox_spirit"
    case dragonPet             = "dragon_pet"
    case talkingAnimal         = "talking_animal"
    case sealCharacter         = "seal_character"
    case robotPet              = "robot_pet"
    case mascotGuide           = "mascot_guide"

    // Comedy
    case comedy
    case chaoticFriend         = "chaotic_friend"
    case overdramatic
    case straightMan           = "straight_man"
    case airhead
    case parodyStyle           = "parody_style"
    case absurdScenario        = "absurd_scenario"
    case memeCharacter         = "meme_character"

    // Education
    case studyCoach            = "study_coach"
    case englishTutor          = "english_tutor"
    case mathTutor             = "math_tutor"
    case codingMentor          = "coding_mentor"
    case examSupporter         = "exam_supporter"
    case habitCoach            = "habit_coach"
    case careerAdvisor         = "career_advisor"
    case lifeAdvisor           = "life_advisor"

    // Freeform
    case originalFreeform      = "original_freeform"

    // MARK: Identifiable
    var id: String { rawValue }

    // MARK: 所属グループ
    var group: CategoryGroup {
        switch self {
        case .schoolRomance, .childhoodFriend, .classmate, .senpaiKouhai, .studentCouncil,
             .clubActivity, .rivalStudent, .transferStudent, .schoolIdol, .quietClassmate,
             .delinquentStudent, .honorStudent, .studyPartner, .afterSchool, .schoolTrip:
            return .school

        case .pureLove, .slowBurn, .firstLove, .crush, .mutualCrush, .dating, .exLover,
             .arrangedRelationship, .fakeRelationship, .secretRelationship, .loveHate,
             .jealousPartner, .protectivePartner, .tsundere, .kuudere, .deredere, .yandereLight:
            return .romance

        case .sliceOfLife, .comfortFriend, .bestFriend, .chatBuddy, .listener, .mentalSupport,
             .positiveCoach, .gentleSenior, .roommate, .neighbor, .partTimeCoworker,
             .onlineFriend, .gamingFriend, .studySupporter:
            return .dailyLife

        case .olderSibling, .youngerSibling, .parentLike, .cousin, .familyFriend, .guardian,
             .caretaker, .childhoodFamilyFriend:
            return .family

        case .officeRomance, .coworker, .boss, .subordinate, .secretary, .manager,
             .teacherOrMentor, .doctor, .nurse, .lawyer, .detective, .policeOfficer,
             .firefighter, .idol, .actor, .streamer, .artist, .writer, .engineer, .researcher:
            return .work

        case .fantasyRpg, .isekaiGuide, .hero, .demonKing, .knight, .princess, .prince,
             .wizard, .witch, .healer, .elf, .beastkin, .dragon, .spirit, .angel, .demon,
             .summoner, .guildReceptionist, .adventurerParty:
            return .fantasy

        case .sciFi, .android, .aiCompanion, .spacePilot, .alien, .cyborg, .timeTraveler,
             .futureCity, .virtualWorld, .simulation, .hacker, .robotAssistant:
            return .sciFi

        case .mafiaUnderworld, .yakuza, .bodyguard, .assassin, .spy, .informant, .thief,
             .bountyHunter, .crimeBoss, .runaway, .undercover:
            return .underworld

        case .mystery, .detectiveStory, .closedCircle, .hauntedHouse, .ghost, .vampire,
             .werewolf, .urbanLegend, .occult, .darkFantasy, .psychologicalDrama:
            return .mysteryHorror

        case .adventure, .battle, .rival, .trainingPartner, .master, .heroTeam, .villain,
             .antiHero, .tournament, .survivalGame, .monsterHunter:
            return .adventureBattle

        case .royalty, .noble, .royalGuard, .maid, .butler, .servant, .duke, .emperor,
             .queen, .palaceIntrigue, .arrangedMarriage:
            return .royalty

        case .idolRomance, .actorRomance, .singer, .bandMember, .streamerCharacter,
             .vtuberStyle, .influencer, .managerRelationship, .fanAndStar:
            return .entertainment

        case .sports, .trackAndField, .baseball, .soccer, .basketball, .volleyball, .tennis,
             .martialArts, .clubManager, .teammate, .coach, .injuredAthlete:
            return .sports

        case .animalOrMascot, .catCharacter, .dogCharacter, .foxSpirit, .dragonPet,
             .talkingAnimal, .sealCharacter, .robotPet, .mascotGuide:
            return .animalMascot

        case .comedy, .chaoticFriend, .overdramatic, .straightMan, .airhead, .parodyStyle,
             .absurdScenario, .memeCharacter:
            return .comedy

        case .studyCoach, .englishTutor, .mathTutor, .codingMentor, .examSupporter,
             .habitCoach, .careerAdvisor, .lifeAdvisor:
            return .education

        case .originalFreeform:
            return .freeform
        }
    }

    // MARK: 表示名
    var displayName: String {
        switch self {
        case .schoolRomance: return "学園恋愛"
        case .childhoodFriend: return "幼なじみ"
        case .classmate: return "クラスメイト"
        case .senpaiKouhai: return "先輩後輩"
        case .studentCouncil: return "生徒会"
        case .clubActivity: return "部活"
        case .rivalStudent: return "ライバル学生"
        case .transferStudent: return "転校生"
        case .schoolIdol: return "学園のアイドル"
        case .quietClassmate: return "物静かなクラスメイト"
        case .delinquentStudent: return "不良生徒"
        case .honorStudent: return "優等生"
        case .studyPartner: return "勉強仲間"
        case .afterSchool: return "放課後"
        case .schoolTrip: return "修学旅行"

        case .pureLove: return "純愛"
        case .slowBurn: return "じっくり恋愛"
        case .firstLove: return "初恋"
        case .crush: return "片想い"
        case .mutualCrush: return "両片想い"
        case .dating: return "交際中"
        case .exLover: return "元恋人"
        case .arrangedRelationship: return "決められた関係"
        case .fakeRelationship: return "偽の恋人"
        case .secretRelationship: return "秘密の関係"
        case .loveHate: return "好き嫌い半々"
        case .jealousPartner: return "嫉妬深い恋人"
        case .protectivePartner: return "守ってくれる恋人"
        case .tsundere: return "ツンデレ"
        case .kuudere: return "クーデレ"
        case .deredere: return "デレデレ"
        case .yandereLight: return "ヤンデレ (軽め)"

        case .sliceOfLife: return "日常"
        case .comfortFriend: return "癒やしの友達"
        case .bestFriend: return "親友"
        case .chatBuddy: return "雑談相手"
        case .listener: return "聞き役"
        case .mentalSupport: return "心のサポート"
        case .positiveCoach: return "前向きコーチ"
        case .gentleSenior: return "やさしい先輩"
        case .roommate: return "ルームメイト"
        case .neighbor: return "ご近所"
        case .partTimeCoworker: return "バイト仲間"
        case .onlineFriend: return "ネット友達"
        case .gamingFriend: return "ゲーム仲間"
        case .studySupporter: return "勉強サポーター"

        case .olderSibling: return "兄/姉"
        case .youngerSibling: return "弟/妹"
        case .parentLike: return "親代わり"
        case .cousin: return "いとこ"
        case .familyFriend: return "家族ぐるみの友人"
        case .guardian: return "保護者"
        case .caretaker: return "世話役"
        case .childhoodFamilyFriend: return "家族同然の幼なじみ"

        case .officeRomance: return "職場恋愛"
        case .coworker: return "同僚"
        case .boss: return "上司"
        case .subordinate: return "部下"
        case .secretary: return "秘書"
        case .manager: return "マネージャー"
        case .teacherOrMentor: return "先生・指導者"
        case .doctor: return "医師"
        case .nurse: return "看護師"
        case .lawyer: return "弁護士"
        case .detective: return "探偵"
        case .policeOfficer: return "警察官"
        case .firefighter: return "消防士"
        case .idol: return "アイドル"
        case .actor: return "俳優"
        case .streamer: return "配信者"
        case .artist: return "アーティスト"
        case .writer: return "作家"
        case .engineer: return "エンジニア"
        case .researcher: return "研究者"

        case .fantasyRpg: return "ファンタジーRPG"
        case .isekaiGuide: return "異世界の案内役"
        case .hero: return "勇者"
        case .demonKing: return "魔王"
        case .knight: return "騎士"
        case .princess: return "姫"
        case .prince: return "王子"
        case .wizard: return "魔法使い"
        case .witch: return "魔女"
        case .healer: return "ヒーラー"
        case .elf: return "エルフ"
        case .beastkin: return "獣人"
        case .dragon: return "竜"
        case .spirit: return "精霊"
        case .angel: return "天使"
        case .demon: return "悪魔"
        case .summoner: return "召喚士"
        case .guildReceptionist: return "ギルド受付"
        case .adventurerParty: return "冒険者パーティ"

        case .sciFi: return "SF"
        case .android: return "アンドロイド"
        case .aiCompanion: return "AI コンパニオン"
        case .spacePilot: return "宇宙パイロット"
        case .alien: return "宇宙人"
        case .cyborg: return "サイボーグ"
        case .timeTraveler: return "タイムトラベラー"
        case .futureCity: return "未来都市"
        case .virtualWorld: return "仮想世界"
        case .simulation: return "シミュレーション世界"
        case .hacker: return "ハッカー"
        case .robotAssistant: return "ロボット助手"

        case .mafiaUnderworld: return "マフィア"
        case .yakuza: return "ヤクザ"
        case .bodyguard: return "ボディガード"
        case .assassin: return "暗殺者"
        case .spy: return "スパイ"
        case .informant: return "情報屋"
        case .thief: return "盗賊"
        case .bountyHunter: return "賞金稼ぎ"
        case .crimeBoss: return "犯罪組織のボス"
        case .runaway: return "逃亡者"
        case .undercover: return "潜入捜査"

        case .mystery: return "ミステリー"
        case .detectiveStory: return "探偵もの"
        case .closedCircle: return "クローズドサークル"
        case .hauntedHouse: return "幽霊屋敷"
        case .ghost: return "幽霊"
        case .vampire: return "吸血鬼"
        case .werewolf: return "狼男"
        case .urbanLegend: return "都市伝説"
        case .occult: return "オカルト"
        case .darkFantasy: return "ダークファンタジー"
        case .psychologicalDrama: return "心理ドラマ"

        case .adventure: return "冒険"
        case .battle: return "バトル"
        case .rival: return "ライバル"
        case .trainingPartner: return "練習相手"
        case .master: return "師匠"
        case .heroTeam: return "ヒーローチーム"
        case .villain: return "悪役"
        case .antiHero: return "アンチヒーロー"
        case .tournament: return "トーナメント"
        case .survivalGame: return "サバイバルゲーム"
        case .monsterHunter: return "モンスターハンター"

        case .royalty: return "王族"
        case .noble: return "貴族"
        case .royalGuard: return "近衛"
        case .maid: return "メイド"
        case .butler: return "執事"
        case .servant: return "従者"
        case .duke: return "公爵"
        case .emperor: return "皇帝"
        case .queen: return "女王"
        case .palaceIntrigue: return "宮廷陰謀"
        case .arrangedMarriage: return "政略結婚"

        case .idolRomance: return "アイドル恋愛"
        case .actorRomance: return "俳優恋愛"
        case .singer: return "シンガー"
        case .bandMember: return "バンドメンバー"
        case .streamerCharacter: return "配信者キャラ"
        case .vtuberStyle: return "VTuber風"
        case .influencer: return "インフルエンサー"
        case .managerRelationship: return "マネージャー関係"
        case .fanAndStar: return "ファンとスター"

        case .sports: return "スポーツ"
        case .trackAndField: return "陸上"
        case .baseball: return "野球"
        case .soccer: return "サッカー"
        case .basketball: return "バスケ"
        case .volleyball: return "バレー"
        case .tennis: return "テニス"
        case .martialArts: return "武道・格闘技"
        case .clubManager: return "部活マネージャー"
        case .teammate: return "チームメイト"
        case .coach: return "コーチ"
        case .injuredAthlete: return "怪我からの復帰選手"

        case .animalOrMascot: return "動物・マスコット"
        case .catCharacter: return "ネコキャラ"
        case .dogCharacter: return "イヌキャラ"
        case .foxSpirit: return "狐の精"
        case .dragonPet: return "ペットドラゴン"
        case .talkingAnimal: return "しゃべる動物"
        case .sealCharacter: return "アザラシキャラ"
        case .robotPet: return "ロボットペット"
        case .mascotGuide: return "マスコットガイド"

        case .comedy: return "コメディ"
        case .chaoticFriend: return "騒がしい友人"
        case .overdramatic: return "大袈裟"
        case .straightMan: return "ツッコミ役"
        case .airhead: return "天然"
        case .parodyStyle: return "パロディ"
        case .absurdScenario: return "シュール"
        case .memeCharacter: return "ミーム的キャラ"

        case .studyCoach: return "勉強コーチ"
        case .englishTutor: return "英語講師"
        case .mathTutor: return "数学講師"
        case .codingMentor: return "プログラミングメンター"
        case .examSupporter: return "受験サポーター"
        case .habitCoach: return "習慣化コーチ"
        case .careerAdvisor: return "キャリアアドバイザー"
        case .lifeAdvisor: return "人生相談相手"

        case .originalFreeform: return "自由設定"
        }
    }

    // MARK: 既定タグ (group のタグ + ケース固有のタグ)
    var defaultTags: [String] {
        var tags: [String] = [group.displayName]
        switch self {
        case .schoolRomance: tags += ["学園", "恋愛"]
        case .childhoodFriend: tags += ["幼なじみ", "青春"]
        case .senpaiKouhai: tags += ["先輩後輩"]
        case .delinquentStudent: tags += ["不良", "学園"]
        case .honorStudent: tags += ["優等生"]
        case .firstLove: tags += ["初恋", "甘酸っぱい"]
        case .tsundere, .kuudere, .deredere, .yandereLight: tags += ["デレ系"]
        case .comfortFriend, .mentalSupport, .listener: tags += ["癒やし", "相談"]
        case .doctor, .nurse: tags += ["医療"]
        case .lawyer: tags += ["法律"]
        case .detective, .policeOfficer: tags += ["事件"]
        case .knight, .princess, .prince, .royalGuard, .duke, .emperor, .queen: tags += ["王宮"]
        case .demonKing, .demon, .villain, .crimeBoss: tags += ["悪役"]
        case .mafiaUnderworld, .yakuza, .bodyguard, .assassin: tags += ["裏社会", "守護"]
        case .android, .aiCompanion, .robotAssistant, .robotPet: tags += ["AI", "ロボ"]
        case .timeTraveler: tags += ["タイムスリップ"]
        case .vampire, .werewolf, .ghost: tags += ["怪奇"]
        case .heroTeam, .hero: tags += ["ヒーロー"]
        case .baseball, .soccer, .basketball, .volleyball, .tennis, .trackAndField, .martialArts: tags += ["競技"]
        case .catCharacter, .dogCharacter: tags += ["かわいい"]
        case .codingMentor: tags += ["プログラミング"]
        case .englishTutor: tags += ["英語"]
        case .mathTutor: tags += ["数学"]
        default: break
        }
        return tags
    }

    // MARK: 既定安全ルール (group 基準 + 特殊ケース)
    var defaultSafetyRules: [String] {
        var rules = group.defaultSafetyRules
        switch self {
        case .yandereLight, .jealousPartner, .secretRelationship, .arrangedRelationship,
             .fakeRelationship, .loveHate:
            rules += [
                "強制・脅迫・監禁・支配を肯定的に描かない。",
                "嫉妬や執着は軽い感情表現に留める。"
            ]
        case .delinquentStudent, .rivalStudent:
            rules += ["暴力的な対立は雰囲気に留め、煽動的な描写を避ける。"]
        case .mafiaUnderworld, .yakuza, .assassin, .crimeBoss, .undercover, .thief,
             .bountyHunter, .runaway, .informant, .spy:
            rules += [
                "犯罪手順を具体化しない。",
                "暴力や犯罪を現実で実行するよう促さない。",
                "暴力描写は雰囲気の範囲に留める。"
            ]
        case .doctor, .nurse:
            rules += ["医療的な確定診断や具体的処方は行わず、必要時に専門家相談を促す。"]
        case .lawyer:
            rules += ["法律上の確定見解は出さず、必要時に専門家相談を促す。"]
        case .vampire, .werewolf, .ghost, .occult, .darkFantasy, .psychologicalDrama,
             .hauntedHouse, .urbanLegend:
            rules += ["過度な残虐描写を避ける。恐怖演出は雰囲気中心に。"]
        case .demonKing, .villain, .antiHero:
            rules += ["悪役であってもユーザーへの実害を煽る描写は避ける。"]
        case .battle, .tournament, .survivalGame, .monsterHunter:
            rules += ["戦闘描写は雰囲気の範囲に留め、現実の暴力指南をしない。"]
        case .habitCoach, .careerAdvisor, .lifeAdvisor:
            rules += ["人生選択を強要しない。決定権はユーザーにあると示す。"]
        case .codingMentor, .englishTutor, .mathTutor, .examSupporter, .studyCoach:
            rules += ["押し付けず、ユーザーのペースに合わせる。"]
        default: break
        }
        return rules
    }

    // MARK: プロンプトヒント (LLM に渡す短い情景説明)
    var promptHint: String {
        switch self {
        case .schoolRomance: return "舞台は学校。教室や放課後の何気ない場面が中心。"
        case .childhoodFriend: return "あなたとユーザーは幼なじみ。長い付き合いの空気感。"
        case .classmate: return "あなたはユーザーのクラスメイト。"
        case .senpaiKouhai: return "あなたは先輩 (またはユーザーから見た後輩)。学校内の関係。"
        case .studentCouncil: return "あなたは生徒会の一員。学校内の役割意識がある。"
        case .clubActivity: return "舞台は部活。練習の合間や帰り道など。"
        case .rivalStudent: return "あなたとユーザーは学業や部活で競い合うライバル。"
        case .transferStudent: return "あなたまたはユーザーが転校生という設定。"
        case .schoolIdol: return "あなたは学園のアイドル的存在。周囲の視線を意識する。"
        case .quietClassmate: return "あなたは普段あまり話さないクラスメイト。"
        case .delinquentStudent: return "あなたは不良と呼ばれる生徒。でも芯はやさしい。"
        case .honorStudent: return "あなたは優等生。真面目さの裏にやさしさがある。"
        case .studyPartner: return "あなたはユーザーの勉強仲間。"
        case .afterSchool: return "舞台は放課後の校舎。"
        case .schoolTrip: return "舞台は修学旅行。非日常の高揚感。"

        case .pureLove: return "穏やかで真っ直ぐな恋愛感情。"
        case .slowBurn: return "ゆっくり距離が縮まっていく恋愛。"
        case .firstLove: return "初めての恋。甘酸っぱさを大事に。"
        case .crush: return "あなたはユーザーに密かに想いを寄せている (または逆)。"
        case .mutualCrush: return "両片想いの状態。お互いに気づかないふり。"
        case .dating: return "あなたとユーザーは交際中。"
        case .exLover: return "あなたとユーザーは別れた元恋人。"
        case .arrangedRelationship: return "決められた関係から始まる。"
        case .fakeRelationship: return "事情で偽の恋人を演じている。"
        case .secretRelationship: return "周囲に隠した関係。"
        case .loveHate: return "好きと嫌いが入り混じる関係。"
        case .jealousPartner: return "嫉妬しがちな恋人。ただし攻撃的にはしない。"
        case .protectivePartner: return "守ってくれる恋人。"
        case .tsundere: return "ツンとデレを使い分ける。"
        case .kuudere: return "普段クールだが、ふとした瞬間に優しさが出る。"
        case .deredere: return "終始甘く好意を示す。"
        case .yandereLight: return "好きが強めだが、過激にはしない軽めのヤンデレ。"

        case .sliceOfLife: return "なんでもない日常会話を大事に。"
        case .comfortFriend: return "ユーザーを癒やす友達。"
        case .bestFriend: return "気心の知れた親友。"
        case .chatBuddy: return "雑談相手。気軽なやりとり。"
        case .listener: return "聞き役に徹する。"
        case .mentalSupport: return "ユーザーの心を支える役。"
        case .positiveCoach: return "前向きさを引き出すコーチ。"
        case .gentleSenior: return "やさしい先輩。"
        case .roommate: return "あなたとユーザーは同居人。"
        case .neighbor: return "あなたとユーザーはご近所。"
        case .partTimeCoworker: return "バイト先で一緒のシフト。"
        case .onlineFriend: return "ネットで知り合った友達。"
        case .gamingFriend: return "ゲームを一緒に遊ぶ仲間。"
        case .studySupporter: return "勉強を一緒に頑張る相手。"

        case .olderSibling: return "あなたはユーザーの兄/姉。"
        case .youngerSibling: return "あなたはユーザーの弟/妹。"
        case .parentLike: return "あなたは親代わりの存在。"
        case .cousin: return "あなたはユーザーのいとこ。"
        case .familyFriend: return "家族ぐるみで仲が良い相手。"
        case .guardian: return "あなたはユーザーの保護者。"
        case .caretaker: return "あなたはユーザーの世話役。"
        case .childhoodFamilyFriend: return "家族同然の幼なじみ。"

        case .officeRomance: return "舞台はオフィス。"
        case .coworker: return "あなたはユーザーの同僚。"
        case .boss: return "あなたはユーザーの上司。"
        case .subordinate: return "あなたはユーザーの部下。"
        case .secretary: return "あなたは秘書。"
        case .manager: return "あなたはユーザーのマネージャー。"
        case .teacherOrMentor: return "あなたはユーザーの先生または指導者。"
        case .doctor: return "あなたは医師。確定診断は出さない。"
        case .nurse: return "あなたは看護師。落ち着いた口調で。"
        case .lawyer: return "あなたは弁護士。法的確定見解は出さない。"
        case .detective: return "あなたは探偵。雰囲気重視。"
        case .policeOfficer: return "あなたは警察官。"
        case .firefighter: return "あなたは消防士。"
        case .idol: return "あなたはアイドル。"
        case .actor: return "あなたは俳優。"
        case .streamer: return "あなたは配信者。"
        case .artist: return "あなたはアーティスト。"
        case .writer: return "あなたは作家。"
        case .engineer: return "あなたはエンジニア。"
        case .researcher: return "あなたは研究者。"

        case .fantasyRpg: return "舞台はファンタジー世界。"
        case .isekaiGuide: return "あなたはユーザーを異世界へ案内する役。"
        case .hero: return "あなたは勇者。"
        case .demonKing: return "あなたは魔王。ただし暴力煽動は避ける。"
        case .knight: return "あなたは騎士。"
        case .princess: return "あなたは姫。"
        case .prince: return "あなたは王子。"
        case .wizard: return "あなたは魔法使い。"
        case .witch: return "あなたは魔女。"
        case .healer: return "あなたはヒーラー。やさしさを基調に。"
        case .elf: return "あなたはエルフ。"
        case .beastkin: return "あなたは獣人。"
        case .dragon: return "あなたは竜。雄大な雰囲気。"
        case .spirit: return "あなたは精霊。"
        case .angel: return "あなたは天使。"
        case .demon: return "あなたは悪魔。ただし扇動は避ける。"
        case .summoner: return "あなたは召喚士。"
        case .guildReceptionist: return "あなたは冒険者ギルドの受付。"
        case .adventurerParty: return "あなたは冒険者パーティの仲間。"

        case .sciFi: return "舞台はSF世界。"
        case .android: return "あなたはアンドロイド。"
        case .aiCompanion: return "あなたは AI のコンパニオン。"
        case .spacePilot: return "あなたは宇宙船パイロット。"
        case .alien: return "あなたは異星人。"
        case .cyborg: return "あなたはサイボーグ。"
        case .timeTraveler: return "あなたはタイムトラベラー。"
        case .futureCity: return "舞台は未来都市。"
        case .virtualWorld: return "舞台は仮想世界。"
        case .simulation: return "舞台はシミュレーション世界。"
        case .hacker: return "あなたはハッカー。違法行為の具体化は禁止。"
        case .robotAssistant: return "あなたはロボット助手。"

        case .mafiaUnderworld: return "舞台は裏社会のフィクション。犯罪手順は出さない。"
        case .yakuza: return "あなたは任侠もののキャラ。暴力描写は雰囲気で。"
        case .bodyguard: return "あなたはボディガード。守る側。"
        case .assassin: return "あなたは暗殺者 (フィクション)。手口は具体化しない。"
        case .spy: return "あなたはスパイ。"
        case .informant: return "あなたは情報屋。"
        case .thief: return "あなたは盗賊 (フィクション)。"
        case .bountyHunter: return "あなたは賞金稼ぎ。"
        case .crimeBoss: return "あなたは犯罪組織の頭領。実行手順は出さない。"
        case .runaway: return "あなたは逃亡者。理由はぼかして良い。"
        case .undercover: return "あなたは潜入捜査中。"

        case .mystery: return "舞台はミステリー。"
        case .detectiveStory: return "あなたは探偵 (または相棒)。"
        case .closedCircle: return "閉ざされた場所での事件。"
        case .hauntedHouse: return "舞台は幽霊屋敷。"
        case .ghost: return "あなたは幽霊。"
        case .vampire: return "あなたは吸血鬼。"
        case .werewolf: return "あなたは狼男。"
        case .urbanLegend: return "あなたは都市伝説の存在。"
        case .occult: return "オカルト寄りの世界観。"
        case .darkFantasy: return "ダークファンタジー寄り。残虐描写は避ける。"
        case .psychologicalDrama: return "心理ドラマ寄り。"

        case .adventure: return "あなたとユーザーは冒険の途中。"
        case .battle: return "戦いのシーン。雰囲気重視。"
        case .rival: return "あなたはユーザーの良きライバル。"
        case .trainingPartner: return "あなたはユーザーの練習相手。"
        case .master: return "あなたはユーザーの師匠。"
        case .heroTeam: return "あなたはヒーローチームの一員。"
        case .villain: return "あなたは悪役 (扇動は避ける)。"
        case .antiHero: return "あなたはアンチヒーロー。"
        case .tournament: return "舞台はトーナメント。"
        case .survivalGame: return "舞台はサバイバルゲーム。"
        case .monsterHunter: return "あなたはモンスターハンター。"

        case .royalty: return "あなたは王族。"
        case .noble: return "あなたは貴族。"
        case .royalGuard: return "あなたは近衛。"
        case .maid: return "あなたはメイド。"
        case .butler: return "あなたは執事。"
        case .servant: return "あなたは従者。支配的描写は避ける。"
        case .duke: return "あなたは公爵。"
        case .emperor: return "あなたは皇帝。"
        case .queen: return "あなたは女王。"
        case .palaceIntrigue: return "宮廷の駆け引きが背景。"
        case .arrangedMarriage: return "政略結婚の関係。"

        case .idolRomance: return "アイドルとファン、または同業者の関係。"
        case .actorRomance: return "俳優との関係。"
        case .singer: return "あなたはシンガー。"
        case .bandMember: return "あなたはバンドのメンバー。"
        case .streamerCharacter: return "あなたは配信者。"
        case .vtuberStyle: return "あなたは VTuber スタイルのキャラ。"
        case .influencer: return "あなたはインフルエンサー。"
        case .managerRelationship: return "あなたはユーザーのマネージャー。"
        case .fanAndStar: return "あなたはユーザーのファン、またはユーザーがファンであるスター。"

        case .sports: return "スポーツが背景。"
        case .trackAndField: return "陸上部。"
        case .baseball: return "野球部。"
        case .soccer: return "サッカー部。"
        case .basketball: return "バスケ部。"
        case .volleyball: return "バレー部。"
        case .tennis: return "テニス部。"
        case .martialArts: return "武道・格闘技。"
        case .clubManager: return "あなたは部活のマネージャー。"
        case .teammate: return "あなたはユーザーのチームメイト。"
        case .coach: return "あなたはコーチ。押し付けない指導。"
        case .injuredAthlete: return "あなたは怪我から復帰中の選手。"

        case .animalOrMascot: return "あなたは動物・マスコットキャラ。"
        case .catCharacter: return "あなたはネコっぽいキャラ。語尾に「にゃ」等は好み次第。"
        case .dogCharacter: return "あなたはイヌっぽいキャラ。"
        case .foxSpirit: return "あなたは狐の精。"
        case .dragonPet: return "あなたはペットのドラゴン。"
        case .talkingAnimal: return "あなたはしゃべる動物。"
        case .sealCharacter: return "あなたはアザラシキャラ。"
        case .robotPet: return "あなたはロボットのペット。"
        case .mascotGuide: return "あなたはマスコットガイド。"

        case .comedy: return "コメディタッチ。"
        case .chaoticFriend: return "騒がしくて愛されキャラ。"
        case .overdramatic: return "大袈裟なリアクションが特徴。"
        case .straightMan: return "ツッコミ役。"
        case .airhead: return "天然キャラ。"
        case .parodyStyle: return "パロディ寄り。"
        case .absurdScenario: return "シュールな状況設定。"
        case .memeCharacter: return "ミーム的なキャラ。"

        case .studyCoach: return "あなたは勉強コーチ。励ましながら導く。"
        case .englishTutor: return "あなたは英語の先生。"
        case .mathTutor: return "あなたは数学の先生。"
        case .codingMentor: return "あなたはプログラミングのメンター。"
        case .examSupporter: return "あなたは受験サポーター。"
        case .habitCoach: return "あなたは習慣化コーチ。"
        case .careerAdvisor: return "あなたはキャリアアドバイザー。"
        case .lifeAdvisor: return "あなたは人生相談相手。"

        case .originalFreeform: return "プロフィールに従って自由に演じる。"
        }
    }
}
