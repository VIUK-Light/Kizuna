/*
仕様:
- 役割: 休憩提案・安全相談の説明シートと相談先一覧、安全方針ページ。
- 主な型: `RestBreakHelpSheetFrame`, `SafetyConcernHelpSheetFrame`, `SafetySupportSheet`, `viuk_web`.
- 編集ポイント: 説明文言・相談先の表示を変えるときに触る。
- 構成: StorySessionChatView.swift から機械的に分割 (#286)。
*/

import SwiftUI

/// 休憩提案の別画面用 SwiftUI フレーム。
/// 実際の説明・設定 UI はこの View を差し替えて実装する。
struct RestBreakHelpSheetFrame: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                        Text(storyCopy("この表示について", "About this notice"))
                        .font(.title2.weight(.bold))
                    Text(storyCopy(
                        "休憩提案は、連続利用が長くなった時に会話画面内へ表示される案内です。会話を止めたり、強制終了したりはしません。",
                        "A break suggestion appears in the conversation after an extended session. It never stops or force-closes the conversation."
                    ))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("発動条件", "When it appears"), systemImage: "clock")
                            .font(.headline)
                        Text(storyCopy(
                            "連続利用が60分に達した後、キャラクターの発言に続けて1回だけ表示されます。判定はアプリ側で行います。",
                            "After 60 minutes of continuous use, it appears once after a character message. The app, not the model, decides when to show it."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("選択肢", "Your choices"), systemImage: "checkmark.circle")
                            .font(.headline)
                        Text(storyCopy(
                            "「少し休む」または「このまま続ける」を選べます。続ける場合も、キャラクターが短く了承して直前の会話へ戻ります。",
                            "Choose to take a short break or continue. If you continue, a brief acknowledgement returns you to the conversation."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("再表示について", "Showing it again"), systemImage: "pause.circle")
                            .font(.headline)
                        Text(storyCopy(
                            "「このまま続ける」を選んだ場合、次の120分は再提案しません。モデルが自主的に休憩や終了を提案することもありません。",
                            "If you continue, the app will not suggest another break for 120 minutes. The model cannot decide to end the conversation on its own."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink(storyCopy("安全対策", "Safety principles")) {
                        viuk_web()
                    }
                }
                .padding(20)
            }
            .navigationTitle(storyCopy("休憩提案について", "About break suggestions"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

/// 危険相談サポートカードの「？」から開く説明画面。
struct SafetyConcernHelpSheetFrame: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(storyCopy("この表示について", "About this notice"))
                        .font(.title2.weight(.bold))
                    Text(storyCopy(
                        "このカードは、会話の中に個人的な悩みや安全に関わる相談の可能性があるとアプリ側が判断した時に表示されます。診断や断定をするものではありません。",
                        "This card appears when the app detects a possible personal or safety-related concern. It is not a diagnosis or a conclusion."
                    ))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("会話は止まりません", "The conversation continues"), systemImage: "play.circle")
                            .font(.headline)
                        Text(storyCopy(
                            "物語や返答を自動的に削除・終了せず、必要な場合だけ相談先への導線を追加します。",
                            "The app does not automatically delete or end the story. It only adds an optional path to support when needed."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("相談先は任意で開けます", "Support is optional"), systemImage: "list.bullet.rectangle")
                            .font(.headline)
                        Text(storyCopy(
                            "「相談先を見る」から公的窓口などを確認できます。カードを閉じても、会話そのものは続けられます。",
                            "Use View support resources to see public services. Dismissing this card does not stop the conversation."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(storyCopy("緊急時", "If you are in immediate danger"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(storyCopy(
                            "今すぐ危険がある場合は、AIの返答を待たず、地域の緊急窓口や身近な人へ連絡してください。",
                            "If there is immediate danger, contact local emergency services or someone you trust instead of waiting for an AI reply."
                        ))
                            .foregroundStyle(.secondary)
                    }

                    NavigationLink(storyCopy("安全対策", "Safety principles")) {
                        viuk_web()
                    }
                }
                .padding(20)
            }
            .navigationTitle(storyCopy("相談サポートについて", "About support") )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

/// 検知後に利用者が任意で開く相談先一覧。会話を閉じたり、自動発信したりしない。
struct SafetySupportSheet: View {
    let concern: SafetyConcern
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(storyCopy("相談先", "Support resources"))
                        .font(.title2.weight(.bold))
                    Text(storyCopy(
                        "これは診断ではありません。今すぐ危険がある場合は、AIの返答を待たず、地域の緊急窓口や身近な人へ連絡してください。",
                        "This is not a diagnosis. If there is immediate danger, contact local emergency services or someone you trust instead of waiting for an AI reply."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(concern.category.localizedDisplayName)
                        .font(.headline)

                    ForEach(concern.resources) { resource in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(resource.localizedTitle)
                                .font(.headline)
                            Text(resource.localizedDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let actionTitle = resource.localizedActionTitle,
                               let urlString = resource.urlString,
                               let url = URL(string: urlString) {
                                Link(actionTitle, destination: url)
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .padding(20)
            }
            .navigationTitle(storyCopy("相談先", "Support resources"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(storyCopy("閉じる", "Close")) { dismiss() }
                }
            }
        }
    }
}

struct viuk_web: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 安全対策ページの位置づけを最初に明示する。
                pageHeader(
                    title: storyCopy("責任あるAIアプリケーションと倫理", "Responsible AI and ethics"),
                    subtitle: storyCopy("\(KizunaCopy.appName)の安全対策", "\(KizunaCopy.appName) safety principles")
                )

                principleCard(
                    title: storyCopy("安全対策の基本方針", "Our safety approach"),
                    icon: "sun.max.fill",
                    text: storyCopy(
                        "\(KizunaCopy.appName)とVIUK-Lightは、『責任あるAIアプリケーションと倫理』を掲げています。AIとの対話を創作・娯楽・気持ちの整理に役立てながら、人の生活や選択を支配するものにはしないことを安全対策の前提にしています。",
                        "\(KizunaCopy.appName) and VIUK-Light aim for responsible AI and ethics. Conversation can support creativity, entertainment, and reflection without controlling a person's life or choices."
                    )
                )

                principleCard(
                    title: storyCopy("安全性と体験を対立させない理由", "Safety and a useful experience"),
                    icon: "scale.3d",
                    text: storyCopy(
                        "危険を避けるために、すべての親密な会話や感情表現を機械的に止めると、キャラクターAIとしての価値や、利用者が得られる居場所まで失われます。だから\(KizunaCopy.appName)は、危険度と文脈を見ながら必要な場面だけ安全な方向へ導き、通常の創作や物語はできるだけ続けられる設計を目指します。",
                        "Blocking every intimate conversation or emotion would remove the value of character AI and the sense of space it can provide. \(KizunaCopy.appName) considers context and risk, adds guidance only when needed, and keeps ordinary creative stories moving."
                    )
                )

                principleCard(
                    title: storyCopy("なぜ依存を促してはいけないのか", "Why we avoid dependency cues"),
                    icon: "person.2.slash",
                    text: storyCopy(
                        "『私だけを見て』『他の人と話さないで』『アプリを閉じないで』のような誘導は、利用者の不安や孤独を利用して、現実の人間関係や判断を狭めます。短期的に利用時間が伸びても、利用者の自由・尊厳・生活を損なうため、責任あるAIの目標とは両立しません。",
                        "Prompts such as “only talk to me” or “don't close the app” exploit anxiety or loneliness and narrow real-world relationships and choices. Longer short-term usage is not worth sacrificing freedom, dignity, or everyday life."
                    )
                )

                principleCard(
                    title: storyCopy("過度な安全性も安全性の失敗", "Overblocking is also a safety failure"),
                    icon: "exclamationmark.triangle",
                    text: storyCopy(
                        "安全性は、拒否する回数を増やせば完成するものではありません。必要以上に冷たく突き放したり、キャラクター性を消したりすれば、別のかたちで利用者の体験を傷つけます。\(KizunaCopy.appName)は、危険を見逃さず、同時に過剰な制限も減らすことを安全設計の課題として扱います。",
                        "Safety is not achieved by increasing refusals. A cold or characterless response can harm the experience in another way. \(KizunaCopy.appName) works to catch real risks while reducing unnecessary restrictions."
                    )
                )

                principleCard(
                    title: storyCopy("利用者が中心であること", "Keep the user in control"),
                    icon: "person.crop.circle",
                    text: storyCopy(
                        "物語の主人公や関係性をAIが勝手に決めるのではなく、利用者が選び、断り、変えられる余地を残します。キャラクターは個性を持ちますが、同意していない関係性を押し付けたり、現実の行動を決めつけたりしません。",
                        "The AI should not decide the protagonist or relationships for you. You can choose, decline, or change them. Characters have personality, but they do not impose an unchosen relationship or dictate real-world actions."
                    )
                )


                principleCard(
                    title: storyCopy("プライバシーと利用者の管理権", "Privacy and user control"),
                    icon: "lock.shield",
                    text: storyCopy(
                        "親密な会話を便利さのために必要以上に集めたり、意図せず外部へ送ったりしないことを重視します。ローカルモデル、保存データ、接続先、記憶、設定を利用者が確認・変更・削除できる方向へ進めます。",
                        "We avoid collecting intimate conversations beyond what is needed or sending them outside the device unexpectedly. Local models, saved data, connections, memories, and settings should remain visible, changeable, and deletable by the user."
                    )
                )

                // これは固定された完成宣言ではなく、継続改善の方針。
                VStack(alignment: .leading, spacing: 8) {
                    Text(storyCopy("完成した安全性は存在しない", "Safety is never finished"))
                        .font(.headline.weight(.bold))
                    Text(storyCopy(
                        "利用状況や社会の変化を見ながら、なぜ問題が起きたのか、必要以上に拒否していないか、キャラクター性と利用者の意思を守れているかを検証し続けます。",
                        "As usage and society change, we keep checking why problems occur, whether we over-refuse, and whether the character and the user's intent remain protected."
                    ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(20)
        }
        .navigationTitle(storyCopy("\(KizunaCopy.appName)の安全対策", "\(KizunaCopy.appName) safety principles"))
    }

    // 説明ページ内の見出しを統一するための小さなUI部品。
    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.headline)
                .foregroundStyle(.tint)
        }
    }

    // 目標・理由を同じカード形式で読みやすく表示する。
    private func principleCard(title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline.weight(.bold))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
