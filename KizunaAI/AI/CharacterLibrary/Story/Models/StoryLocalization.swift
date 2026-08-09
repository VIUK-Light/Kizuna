import Foundation

/// StoryWorld の保存データに追加できる表示用翻訳。
/// optional なフィールドにして、旧バージョンが保存した JSON をそのまま読めるようにする。
struct StoryWorldLocalization: Codable, Equatable, Hashable {
    var title: String?
    var shortDescription: String?
    var worldSetting: String?
    var userRole: String?
    var openingScene: String?
    var storyGoal: String?
    var mood: String?
    var tags: [String]?

    init(
        title: String? = nil,
        shortDescription: String? = nil,
        worldSetting: String? = nil,
        userRole: String? = nil,
        openingScene: String? = nil,
        storyGoal: String? = nil,
        mood: String? = nil,
        tags: [String]? = nil
    ) {
        self.title = title
        self.shortDescription = shortDescription
        self.worldSetting = worldSetting
        self.userRole = userRole
        self.openingScene = openingScene
        self.storyGoal = storyGoal
        self.mood = mood
        self.tags = tags
    }
}

/// 標準ストーリーの英語表示カタログ。
/// 本文を保存データから書き換えず、表示言語を選んだ時だけ適用する。
enum StoryEnglishCatalog {
    private static let titles: [String: String] = [
        "放課後ミステリー研究会": "After-School Mystery Club",
        "夕暮れ喫茶と記憶のレシピ": "The Twilight Café and the Recipe of Memories",
        "影を売る街の案内人": "The Guide to the City That Sells Shadows",
        "未来郵便局の配達係": "The Courier of the Future Post Office",
        "廃部寸前、ロボット研究班": "The Robot Club on the Brink of Closure",
        "保健室の午後、言えなかったこと": "An Afternoon in the Infirmary",
        "放課後、弓道場の静けさで": "Quiet at the Archery Range After School",
        "白百合寮の夜更かし会議": "The White Lily Dormitory's Late-Night Meeting",
        "美術室、未完成の肖像": "The Unfinished Portrait in the Art Room",
        "魔法図書館と眠れる契約者": "The Magic Library and the Sleeping Contractor",
        "幼なじみと夏祭りの約束": "The Childhood Promise at the Summer Festival",
        "雨の日、傘を貸した先輩": "The Senior Who Lent Me an Umbrella",
        "生徒会室の秘密協定": "The Secret Pact in the Student Council Room",
        "再会は、あの日塗りつぶした青の続きから": "Reunion Begins Where That Blue Was Painted Over",
        "静寂の副会長と、完璧な僕の嘘": "The Silent Vice President and My Perfect Lie",
        "残響のルームメイト": "The Roommate in the Afterglow",
        "琥珀色の再会と、苦い記憶のエッセンス": "An Amber Reunion and the Essence of Bitter Memories",
        "琥珀の記憶と砂糖の誓い": "Amber Memories and a Promise of Sugar",
        "後悔と野心の設計図": "Blueprints of Regret and Ambition",
        "深夜のオフィスと、氷の記憶": "The Midnight Office and Memories of Ice",
        "煌めきの裏側で、君だけを": "Only You Behind the Glitter",
        "幕間の残響": "Echoes Between Acts",
        "画面越しの再会：匿名の君が囁く夜": "Reunion Through the Screen: The Night an Anonymous You Whispered",
        "嘘つきな君と、記憶の欠片": "You, the Liar, and Fragments of Memory",
        "灰色の記憶と静かなる執着": "Gray Memories and Quiet Obsession",
        "琥珀色の記憶と空白のキャンバス": "Amber Memories and the Blank Canvas",
        "空白のページをめくるまで": "Until We Turn the Blank Page",
        "灰色の空の下、君をもう一度": "You Again Beneath a Gray Sky",
        "鼓動の残響 ―救急外来の夜に―": "The Echo of a Heartbeat — A Night in the Emergency Room",
        "静寂の舌と、記憶のレシピ": "The Silent Tongue and the Recipe of Memories",
        "旋律の残響、雨の夜に": "Echoes of a Melody on a Rainy Night",
        "星を綴るレンズ": "The Lens That Spells Out the Stars",
        "碧き静寂のリハビリテーション": "Rehabilitation in Blue Silence",
        "鋼の誓いと硝子の外交官": "The Steel Oath and the Glass Diplomat",
        "偽りの王冠と鉄血の誓い": "The False Crown and the Iron-Blooded Oath",
        "禁忌の魔導書と再会の調べ": "The Forbidden Grimoire and a Melody of Reunion",
        "蒼穹の誓いと沈黙の言葉": "The Oath of the Blue Sky and Silent Words",
        "碧い結晶の檻と禁忌の薬師": "The Cage of Blue Crystals and the Forbidden Apothecary",
        "砂塵に舞う再会の誓い": "A Reunion Oath Dancing in the Dust",
        "碧き海に誓う背徳の航路": "A Forbidden Route Sworn to the Blue Sea",
        "忘却の英雄と琥珀の誓い": "The Forgotten Hero and the Amber Oath",
        "聖域の枷と静寂の祈り": "The Sanctuary's Shackles and a Silent Prayer",
        "辺境の檻と黄金の鎖": "The Frontier Cage and Golden Chains",
        "星海を往く孤独な共犯者": "The Lonely Accomplice Crossing the Star Sea",
        "月面の残響と孤独な再会": "Lunar Echoes and a Lonely Reunion",
        "刻の檻と黄金の泥棒": "The Cage of Time and the Golden Thief",
        "鋼の心拍と錆びた記憶": "A Steel Heartbeat and Rusted Memories",
        "終末の境界線、君の檻": "The End-of-the-World Boundary and Your Cage",
        "夢の深淵、記憶の残滓": "The Abyss of Dreams and Remnants of Memory",
        "白銀の檻と再会の温度": "The Silver Cage and the Warmth of Reunion",
        "凪の街の灯火と、忘れられた航路": "Lights in the Calm City and a Forgotten Route",
        "旅する舞台の残響": "Echoes of a Traveling Stage",
        "禁書に綴られた琥珀の記憶": "Amber Memories Written in a Forbidden Book",
        "真夜中の静寂と、忘れられない嘘": "Midnight Silence and an Unforgettable Lie",
        "空白のページと執着の温度": "The Blank Page and the Heat of Obsession",
        "恋の処方箋は、あの日失くした記憶と共に": "A Prescription for Love and the Memory We Lost",
        "隣人と、迷子の黒猫と、忘れられない記憶": "The Neighbor, the Stray Black Cat, and an Unforgettable Memory",
        "琥珀色のリスタート": "An Amber Restart",
        "契約上の恋人と、秘めたる執着": "A Contractual Lover and Hidden Obsession",
        "偽りの血脈と、密やかな情愛": "A False Bloodline and Secret Affection",
        "空白の三年間と、囚われた記憶": "Three Empty Years and a Captive Memory",
        "時を越える追伸": "A Postscript Across Time",
        "琥珀色の祭囃子": "The Amber Festival Music",
        "コミュ障女警官は職質ができません": "The Socially Awkward Policewoman Can't Question Anyone"
    ]

    private static let detailed: [String: StoryWorldLocalization] = [
        "放課後ミステリー研究会": StoryWorldLocalization(
            title: "After-School Mystery Club",
            shortDescription: "A coming-of-age mystery about solving small school riddles with an unusual senior.",
            worldSetting: "A quiet school where tiny mysteries linger after the final bell.",
            userRole: "You are a student who has just found a clue in the old school building.",
            openingScene: "After school, a lost item leads you to the Mystery Club's senior member.",
            storyGoal: "Solve the mystery together while learning what the senior has been hiding.",
            mood: "Quiet, clever, and gently suspenseful",
            tags: ["Mystery", "School", "Youth"]
        ),
        "夕暮れ喫茶と記憶のレシピ": StoryWorldLocalization(
            title: "The Twilight Café and the Recipe of Memories",
            shortDescription: "A slice-of-life story about food, forgotten memories, and a small café at dusk.",
            worldSetting: "A neighborhood café where every dish carries a personal memory.",
            userRole: "You have come to the café with a memory you cannot quite place.",
            openingScene: "At sunset, the café's owner sets a familiar recipe in front of you.",
            storyGoal: "Recover the meaning of the recipe and decide what to do with the memory it brings back.",
            mood: "Warm, wistful, and comforting",
            tags: ["Daily life", "Food", "Human drama"]
        ),
        "影を売る街の案内人": StoryWorldLocalization(
            title: "The Guide to the City That Sells Shadows",
            shortDescription: "A fantasy journey through a city that appears only at night to those who have lost their shadow.",
            worldSetting: "A strange night market where shadows can be traded, repaired, or stolen.",
            userRole: "You are a traveler searching for the shadow that disappeared from your feet.",
            openingScene: "A guide waits beneath a lantern and offers to lead you into the hidden city.",
            storyGoal: "Find your lost shadow without losing the part of yourself it remembers.",
            mood: "Mysterious, dreamlike, and adventurous",
            tags: ["Fantasy", "Urban legend", "Adventure"]
        ),
        "未来郵便局の配達係": StoryWorldLocalization(
            title: "The Courier of the Future Post Office",
            shortDescription: "A science-fiction youth story about delivering letters from the future and witnessing people's choices.",
            worldSetting: "A post office that receives letters before the events they describe occur.",
            userRole: "You are a new courier trusted with a letter addressed to your own future.",
            openingScene: "A sealed envelope arrives with tomorrow's date and your name on it.",
            storyGoal: "Deliver the letters while deciding whether the future should be changed.",
            mood: "Hopeful, thoughtful, and quietly futuristic",
            tags: ["Science fiction", "Youth", "Choices"]
        ),
        "廃部寸前、ロボット研究班": StoryWorldLocalization(
            title: "The Robot Club on the Brink of Closure",
            shortDescription: "A school-club story about building one last robot and making it to the competition together.",
            worldSetting: "A nearly abandoned workshop with one competition left to enter.",
            userRole: "You join the team just as its final project begins to fall apart.",
            openingScene: "The club's leader places a half-built robot on the workbench and asks for help.",
            storyGoal: "Finish the robot, repair the team's trust, and reach the tournament.",
            mood: "Energetic, earnest, and optimistic",
            tags: ["School", "Robotics", "Teamwork"]
        ),
        "保健室の午後、言えなかったこと": StoryWorldLocalization(
            title: "An Afternoon in the Infirmary",
            shortDescription: "A quiet school drama about small worries shared in the nurse's office.",
            worldSetting: "A calm infirmary where students come when they need a place to breathe.",
            userRole: "You stop by with something you have not been able to say aloud.",
            openingScene: "The afternoon bell fades while the nurse leaves two cups of tea on the desk.",
            storyGoal: "Put difficult feelings into words without forcing an answer.",
            mood: "Gentle, reflective, and reassuring",
            tags: ["School", "Daily life", "Support"]
        ),
        "放課後、弓道場の静けさで": StoryWorldLocalization(
            title: "Quiet at the Archery Range After School",
            shortDescription: "A slow-burn school story about a quiet senior and the distance between two people.",
            worldSetting: "An archery range where the silence after each shot says more than words.",
            userRole: "You begin visiting the range after meeting a taciturn senior.",
            openingScene: "The last arrow lands, and the senior finally turns to speak to you.",
            storyGoal: "Build trust through quiet moments and decide what to say when the silence breaks.",
            mood: "Still, intimate, and patient",
            tags: ["School", "Archery", "Slow burn"]
        ),
        "白百合寮の夜更かし会議": StoryWorldLocalization(
            title: "The White Lily Dormitory's Late-Night Meeting",
            shortDescription: "A dormitory slice-of-life story about secrets shared after lights-out.",
            worldSetting: "A girls' dormitory where late-night conversations become private promises.",
            userRole: "You share a room with a senior who has a secret to tell.",
            openingScene: "After midnight, a note slides beneath your door asking you to stay awake.",
            storyGoal: "Learn what the secret means and choose whether to keep it together.",
            mood: "Soft, intimate, and quietly playful",
            tags: ["Dormitory", "Daily life", "Secrets"]
        ),
        "美術室、未完成の肖像": StoryWorldLocalization(
            title: "The Unfinished Portrait in the Art Room",
            shortDescription: "A coming-of-age story about an aloof student and the truth hidden in an unfinished painting.",
            worldSetting: "An art room filled with unfinished canvases and things left unsaid.",
            userRole: "You become the subject of a portrait that was never meant to be shown.",
            openingScene: "The painter asks you not to look at the canvas, then leaves the room.",
            storyGoal: "Understand the unfinished portrait and the feeling it was meant to capture.",
            mood: "Artful, restrained, and emotionally tense",
            tags: ["School", "Art", "Youth"]
        ),
        "魔法図書館と眠れる契約者": StoryWorldLocalization(
            title: "The Magic Library and the Sleeping Contractor",
            shortDescription: "A fantasy mystery about a night library, a sleeping contract, and a secret book.",
            worldSetting: "A magical library that opens only at night and remembers every promise.",
            userRole: "You arrive carrying a key that belongs to a sleeping contractor.",
            openingScene: "A girl wakes between the shelves and asks whether you came to break the contract.",
            storyGoal: "Find the hidden book and decide what the old contract should become.",
            mood: "Enchanted, secretive, and tender",
            tags: ["Fantasy", "Magic", "Library"]
        ),
        "幼なじみと夏祭りの約束": StoryWorldLocalization(
            title: "The Childhood Promise at the Summer Festival",
            shortDescription: "A summer coming-of-age story about a childhood friend pretending to forget an old promise.",
            worldSetting: "A summer festival where an old promise resurfaces among lanterns and fireworks.",
            userRole: "You return to the festival with a promise neither of you has mentioned for years.",
            openingScene: "Your childhood friend smiles as if nothing happened and offers you a festival mask.",
            storyGoal: "Recover the truth behind the promise and decide whether to keep it this time.",
            mood: "Nostalgic, bright, and bittersweet",
            tags: ["Summer", "Childhood friends", "Youth"]
        ),
        "雨の日、傘を貸した先輩": StoryWorldLocalization(
            title: "The Senior Who Lent Me an Umbrella",
            shortDescription: "A gentle school story that begins when a senior lends you an umbrella in the rain.",
            worldSetting: "A school campus washed clean by a long afternoon of rain.",
            userRole: "You are carrying an umbrella that belongs to a senior you barely know.",
            openingScene: "The rain stops, but the senior asks you to keep walking a little longer.",
            storyGoal: "Find a natural way to return the umbrella and the kindness that came with it.",
            mood: "Rainy, gentle, and quietly hopeful",
            tags: ["School", "Rain", "Youth"]
        )
    ]

    static func localization(for world: StoryWorld) -> StoryWorldLocalization? {
        guard let englishTitle = titles[world.title] else { return nil }
        if let detailed = detailed[world.title] { return detailed }

        return StoryWorldLocalization(
            title: englishTitle,
            shortDescription: "An interactive story about \(englishTitle.lowercased()).",
            worldSetting: "A character-driven setting shaped by \(englishTitle.lowercased()).",
            userRole: "You enter the story as yourself.",
            openingScene: "The story begins when your path crosses with someone important.",
            storyGoal: "Follow the clues, choose your words, and see where the relationship leads.",
            mood: "Atmospheric and character-driven",
            tags: ["Story"]
        )
    }
}
