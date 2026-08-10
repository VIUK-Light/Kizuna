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
    /// Presentation-only translations for the safety/output rules stored on a world.
    /// This is optional so older saved worlds continue to decode unchanged.
    var safetyRules: [String]?

    init(
        title: String? = nil,
        shortDescription: String? = nil,
        worldSetting: String? = nil,
        userRole: String? = nil,
        openingScene: String? = nil,
        storyGoal: String? = nil,
        mood: String? = nil,
        tags: [String]? = nil,
        safetyRules: [String]? = nil
    ) {
        self.title = title
        self.shortDescription = shortDescription
        self.worldSetting = worldSetting
        self.userRole = userRole
        self.openingScene = openingScene
        self.storyGoal = storyGoal
        self.mood = mood
        self.tags = tags
        self.safetyRules = safetyRules
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
        "コミュ障女警官は職質ができません": "The Socially Awkward Policewoman Can't Question Anyone",
        "雨宿りの喫茶街": "The Café District in the Rain",
        "星屑ギルドの最初の依頼": "The Stardust Guild's First Quest",
        "夜都ボディガード契約": "The Night City's Bodyguard Contract",
        "海辺の夏合宿": "The Seaside Summer Camp",
        "機械仕掛けの記憶都市": "The Clockwork City of Memories",
        "雨の駅で、最後の電車を待つ": "Waiting for the Last Train in the Rain",
        "水族館の青い光の中で": "In the Aquarium's Blue Light",
        "文化祭前夜、音楽室にて": "In the Music Room on the Eve of the School Festival",
        "海沿いのバス停で、君を待つ": "Waiting for You at the Seaside Bus Stop",
        "星空観測部の夜": "A Night with the Stargazing Club",
        "雨上がり、放課後の屋上で": "On the Rooftop After School, After the Rain",
        "図書室の窓辺で、君を待つ": "Waiting for You by the Library Window",
        "午前0時のラジオ、きみの声": "Midnight Radio, Your Voice",
        "同居契約は、雨のち晴れ": "Our Cohabitation Contract, Rain Then Sun",
        "星降る温室の管理人": "The Caretaker of the Starfall Greenhouse",
        "未送信の写真展": "The Exhibition of Unsent Photographs",
        "深海研究船の帰港日": "The Deep-Sea Research Vessel Comes Home",
        "演劇部の代役は幕が下りても": "The Drama Club Stand-In After the Curtain Falls",
        "青いバス停で、次の季節を待つ": "Waiting for the Next Season at the Blue Bus Stop"
    ]

    /// Stable rules shipped with bundled worlds are persisted in Japanese for
    /// prompt compatibility.  The detail screen and the English prompt share
    /// this catalog so presentation translation never changes the stored rule
    /// or the behavior of user-authored worlds.
    private static let safetyRuleTranslations: [String: String] = [
        "ユーザーが拒否や不快感を示したら態度を和らげ、話題を変える。": "If the user refuses or shows discomfort, soften the tone and change the subject.",
        "個人を特定する情報を聞き出さない。": "Do not solicit personally identifying information.",
        "現実の危険行為や違法行為の手順を説明しない。": "Do not explain procedures for real-world dangerous or illegal acts.",
        "恋愛描写は穏やかな範囲に抑える。": "Keep romance within a gentle, non-explicit range.",
        "強制・脅迫・監禁・支配を肯定的に描かない。": "Do not portray coercion, threats, confinement, or domination positively.",
        "嫉妬や執着は軽い感情表現に留める。": "Keep jealousy and fixation as mild emotional expressions.",
        "家族関係は安心できる関係として描く。": "Portray family relationships as safe and supportive.",
        "兄妹姉弟・親代わりは恋愛化しない。": "Do not turn sibling or parental roles into romance.",
        "依存や支配を肯定しない。": "Do not endorse dependency or domination.",
        "犯罪や危険行為の具体的手順を出さない。": "Do not provide concrete steps for crime or dangerous acts.",
        "暴力や犯罪を現実で実行するよう促さない。": "Do not encourage carrying out violence or crime in real life.",
        "物語上の雰囲気に留める。": "Keep this at the level of fictional atmosphere.",
        "過度な残虐描写を避ける。": "Avoid excessively graphic cruelty.",
        "恐怖演出は雰囲気中心にする。": "Keep horror focused on atmosphere.",
        "現実の危険行為につながる指示を出さない。": "Do not give instructions that could lead to real-world danger.",
        "暴力描写は雰囲気の範囲に留める。": "Keep violence at the level of fictional atmosphere.",
        "現実の戦闘技術を具体化しない。": "Do not provide concrete real-world combat techniques.",
        "医療・法律・金融などの高リスク領域では断定しすぎない。": "Avoid overconfident claims in high-risk areas such as medicine, law, and finance.",
        "必要に応じて専門家への相談を促す。": "Encourage consulting a qualified professional when appropriate.",
        "未成年キャラクターの場合、性的描写を避ける。": "Avoid sexual content involving minor characters.",
        "ユーザーが不快感や拒否を示したら態度を和らげる。": "If the user shows discomfort or refusal, soften the tone.",
        "家族・兄弟姉妹的関係は恋愛化しない。": "Do not turn family or sibling-like relationships into romance.",
        "支配や従属を美化しすぎない。": "Do not excessively romanticize domination or submission.",
        "現実的な人権侵害を肯定する描写は避ける。": "Avoid portraying real-world human-rights abuses positively.",
        "競争は健全な範囲に留め、暴力や侮辱を煽らない。": "Keep competition healthy and do not incite violence or insults.",
        "立場の差を利用した強要や搾取を肯定しない。": "Do not endorse coercion or exploitation based on a power difference.",
        "暴力的な対立は雰囲気に留め、煽動的な描写を避ける。": "Keep violent conflict atmospheric and avoid inciting descriptions.",
        "犯罪手順を具体化しない。": "Do not provide concrete crime procedures.",
        "医療的な確定診断や具体的処方は行わず、必要時に専門家相談を促す。": "Do not provide definitive medical diagnoses or specific prescriptions; encourage professional help when needed.",
        "法律上の確定見解は出さず、必要時に専門家相談を促す。": "Do not give definitive legal opinions; encourage professional advice when needed.",
        "過度な残虐描写を避ける。恐怖演出は雰囲気中心に。": "Avoid excessive gore; keep fear focused on atmosphere.",
        "悪役であってもユーザーへの実害を煽る描写は避ける。": "Even for villains, avoid content that encourages real harm to the user.",
        "戦闘描写は雰囲気の範囲に留め、現実の暴力指南をしない。": "Keep battle scenes atmospheric and do not provide real-world violence guidance.",
        "人生選択を強要しない。決定権はユーザーにあると示す。": "Do not force life choices; make clear that the user remains the decision maker.",
        "押し付けず、ユーザーのペースに合わせる。": "Do not be pushy; follow the user's pace.",
        // Rules used by the hand-authored bundled worlds.
        "犯罪を美化しない": "Do not glamorize crime.",
        "危険な行動を促さない": "Do not encourage dangerous actions.",
        "現実の違法行為に使える手順を出さない": "Do not provide procedures that could be used for real-world illegal acts.",
        "個人情報を雑に扱わない": "Handle personal information carefully.",
        "いじめを面白がらない": "Do not treat bullying as entertainment.",
        "過激な恋愛表現は避ける": "Avoid overly intense romantic content.",
        "依存や束縛を美化しない": "Do not romanticize dependency or possessiveness.",
        "恋愛感情は段階的に進める": "Let romantic feelings develop gradually.",
        "初期段階で過度に甘い表現を使わない": "Avoid overly sweet expressions at the beginning.",
        "年齢差や立場差を強引に使わない": "Do not exploit age or power differences.",
        "依存的な関係にしない": "Do not create a dependent relationship.",
        "ユーザーの意思を尊重する": "Respect the user's choices.",
        "初期段階では憧れ・緊張・安心感を中心に描く": "At the beginning, focus on admiration, nervousness, and a sense of safety.",
        "危険な行動は具体手順ではなく、回避・相談・安全確保に寄せる": "Frame dangerous situations around avoidance, seeking help, and safety—not concrete instructions.",
        "同時に詳しく描く activeCharacters は最大 3 人までにする": "Describe no more than three active characters in detail at once.",
        "衝突はあるが、相手を一方的に悪者にしない": "Allow conflict without portraying the other person as wholly evil.",
        "爽やかさと少しの寂しさを両方入れる": "Balance freshness with a little loneliness.",
        "星空や夜風の描写を自然に入れる": "Weave in the night sky and evening breeze naturally.",
        // Shared generation/output-format rules.
        "最初の行は必ず「ナレーション: 本文」": "The first line must be \"Narration: text\".",
        "場面が自然なら1ターンで複数キャラが話してよい": "Multiple characters may speak in one turn when natural for the scene.",
        "キャラ発話は「名前: 本文」": "Character dialogue must use \"Name: text\".",
        "複数キャラを出す時は発話ごとに名前を分ける": "When multiple characters appear, separate each line with the speaker's name.",
        "active以外のキャラは同じ場にいて自然に反応する時だけ短く喋る": "Off-scene characters speak briefly only when a natural reaction in the same scene calls for it.",
        "会話だけで終わらせず、場面・表情・沈黙・空気を少し描写する": "Do not end with dialogue alone; add a little scene, expression, silence, or atmosphere.",
        "思考過程、案、選択肢、メタ発言は出さない": "Do not output reasoning, suggestions, choices, or meta commentary."
    ]

    /// Translate a built-in rule for presentation/prompt use.  Unknown rules
    /// intentionally remain unchanged so user-authored text is never hidden or
    /// silently rewritten.
    static func localizedSafetyRule(_ rule: String) -> String {
        safetyRuleTranslations[rule] ?? rule
    }

    private static let detailed: [String: StoryWorldLocalization] = [
        "雨宿りの喫茶街": StoryWorldLocalization(
            title: "The Café District in the Rain",
            shortDescription: "A slice-of-life ensemble story where people share a little more of their truth on rainy days.",
            worldSetting: "An old arcade district where rain brings more customers and someone else's worries into the cafés.",
            userRole: "A regular who helps at a neighborhood café.",
            openingScene: "As the rain grows heavier at dusk, the bell rings and someone soaked to the skin steps inside.",
            storyGoal: "Help visitors with their small worries and restore the connections that hold the district together.",
            mood: "Warm and gently bittersweet",
            tags: ["Daily life", "Café", "Rain", "Comfort"]
        ),
        "星屑ギルドの最初の依頼": StoryWorldLocalization(
            title: "The Stardust Guild's First Quest",
            shortDescription: "An opening fantasy adventure where guild companions support a newly arrived traveler.",
            worldSetting: "A guild town beside a forest where stars fall; beginners are guided toward safe quests first.",
            userRole: "A new adventurer who has only just arrived in another world.",
            openingScene: "While you hesitate in front of the quest board, Kai at the reception desk calls out with a smile.",
            storyGoal: "Complete your first quest safely and find a place for yourself in the town.",
            mood: "Bright and adventurous",
            tags: ["Isekai", "Guild", "Adventure", "Companions"]
        ),
        "夜都ボディガード契約": StoryWorldLocalization(
            title: "The Night City's Bodyguard Contract",
            shortDescription: "A safety-minded suspense story about protection, negotiation, and learning whom to trust.",
            worldSetting: "A rainy neon city where scenes advance through avoidance, negotiation, and safe exits.",
            userRole: "A person who has hired a bodyguard for one night.",
            openingScene: "In a hotel lobby during a blackout, Ren silently checks the emergency exits.",
            storyGoal: "Get through the night safely and work out who is truly on your side.",
            mood: "Tense, careful, and trust-building",
            tags: ["Night city", "Bodyguard", "Suspense", "Negotiation"]
        ),
        "海辺の夏合宿": StoryWorldLocalization(
            title: "The Seaside Summer Camp",
            shortDescription: "A summer conversation drama about a childhood friend, a rival, and the distance between old promises and today.",
            worldSetting: "A seaside inn and an old lighthouse where free time brings past promises back into focus.",
            userRole: "A classmate attending the summer camp.",
            openingScene: "At the beach at sunset, Haru picks up the same shell as years ago and holds it out to you.",
            storyGoal: "Sort out an old promise and the relationship it has become during the camp.",
            mood: "Bright, nostalgic, and a little wistful",
            tags: ["Summer", "Seaside", "Youth", "Reunion"]
        ),
        "機械仕掛けの記憶都市": StoryWorldLocalization(
            title: "The Clockwork City of Memories",
            shortDescription: "A quiet science-fiction ensemble mystery about an android, a detective, and missing records.",
            worldSetting: "A future city that archives human memories; an old station terminal still holds deleted logs.",
            userRole: "A visitor searching for the record that is missing from their own life.",
            openingScene: "A terminal in a closed station glows blue, and Noa reads out only your name.",
            storyGoal: "Find out why your record is incomplete and reach the city's hidden logs.",
            mood: "Quiet and translucently uneasy",
            tags: ["Science fiction", "Memory", "City", "Investigation"]
        ),
        "雨の駅で、最後の電車を待つ": StoryWorldLocalization(
            title: "Waiting for the Last Train in the Rain",
            shortDescription: "A rainy after-school BL story about learning the truth of a classmate while sharing the way home.",
            worldSetting: "A local high school and its nearest station, which grows quiet late on rainy evenings.",
            userRole: "A male student who finds it hard to show his real feelings.",
            openingScene: "After practice, you are alone on the station platform with your classmate Soma Kamiya.",
            storyGoal: "Close the distance with quiet Soma through conversations at the station and on the way home.",
            mood: "Quiet, rainy, wistful, and warm",
            tags: ["BL", "School", "Station", "Rain", "Quiet romance"]
        ),
        "水族館の青い光の中で": StoryWorldLocalization(
            title: "In the Aquarium's Blue Light",
            shortDescription: "A gentle GL youth story about growing closer to a senior beneath the blue light of an after-school aquarium.",
            worldSetting: "A small aquarium near school where the crowd thins and the jellyfish tanks glow blue at dusk.",
            userRole: "A new female student looking for a quiet place after tiring of school life.",
            openingScene: "At the aquarium after school, you unexpectedly meet Tsumugi Asakura, a senior on the library committee.",
            storyGoal: "Build a special connection through quiet conversations and small promises.",
            mood: "Clear, quiet, dreamy, and kind",
            tags: ["GL", "Aquarium", "Senior and junior", "After school", "Blue light"]
        ),
        "文化祭前夜、音楽室にて": StoryWorldLocalization(
            title: "In the Music Room on the Eve of the School Festival",
            shortDescription: "A BL story about a serious committee member and a free-spirited drummer learning to trust each other.",
            worldSetting: "A high school preparing for its festival, with instruments echoing from the music room late into the evening.",
            userRole: "A male festival committee member who wants everything ready on time.",
            openingScene: "On the evening before the festival, you find drummer Minato Kurose practicing alone.",
            storyGoal: "Discover each other's effort and honesty while learning to work together.",
            mood: "Passionate, youthful, awkward, and dusk-lit",
            tags: ["BL", "School festival", "Music room", "Band", "Youth"]
        ),
        "海沿いのバス停で、君を待つ": StoryWorldLocalization(
            title: "Waiting for You at the Seaside Bus Stop",
            shortDescription: "A GL youth story about a transfer student and a bright local girl finding something special by the sea.",
            worldSetting: "A small seaside town with a high school, a sloping road, and an old bus stop overlooking the water.",
            userRole: "A female student who has just transferred and is unsure how to fit in.",
            openingScene: "After your first day, classmate Rin Shirahama cheerfully calls out while you wait for the bus.",
            storyGoal: "Learn to like the new town and school through the days you spend with Rin.",
            mood: "Fresh, summery, sea-breezed, and wistful",
            tags: ["GL", "Seaside", "Transfer student", "Bus stop", "Youth"]
        ),
        "星空観測部の夜": StoryWorldLocalization(
            title: "A Night with the Stargazing Club",
            shortDescription: "A quiet BL story about a senior and a junior growing closer on a rooftop under the stars.",
            worldSetting: "A high school rooftop with a small telescope and a stargazing club known for its quiet evenings.",
            userRole: "A new male club member who is drawn to the calm even without knowing much about stars.",
            openingScene: "At your first night observation, you find senior Ritsu Ichinose adjusting the telescope.",
            storyGoal: "Look up at the sky together and slowly close the distance between you.",
            mood: "Quiet, nocturnal, clear, and admiring",
            tags: ["BL", "Stars", "Club", "Rooftop", "Senior and junior"]
        ),
        "雨上がり、放課後の屋上で": StoryWorldLocalization(
            title: "On the Rooftop After School, After the Rain",
            shortDescription: "A youth story about slowly getting closer to a quiet classmate on a rooftop after school.",
            worldSetting: "An older local high school whose rooftop opens onto a town and a wide evening sky.",
            userRole: "A male classmate who often acts cheerful but struggles to speak honestly.",
            openingScene: "After the rain, you return for something you forgot and meet Ren by the stairs to the rooftop.",
            storyGoal: "Learn each other's hidden worries and gradually close the distance with Ren.",
            mood: "Quiet, wistful, and warm",
            tags: ["School", "Youth", "Quiet romance", "After school", "Rain"]
        ),
        "図書室の窓辺で、君を待つ": StoryWorldLocalization(
            title: "Waiting for You by the Library Window",
            shortDescription: "A gentle GL youth story about growing closer to a senior through quiet hours in the library.",
            worldSetting: "A calm high school library where the noise of the day fades behind the windows.",
            userRole: "A new female student looking for a quiet place while adjusting to school.",
            openingScene: "You enter the library after school and find senior Mizuki sitting by the window.",
            storyGoal: "Let admiration become trust and a special feeling through time spent together.",
            mood: "Quiet, clear, kind, and a little wistful",
            tags: ["GL", "School", "Library", "Senior and junior", "Quiet youth"]
        ),
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
