import Foundation

/// 会話の流れから生まれる、短時間で終わる物語上の出来事。
enum StoryEventStatus: String, Codable, Equatable, Hashable {
    case active
    case resolved
    case abandoned
}

/// モデルが同じ応答の隠しSTATE_UPDATEで返せるイベント操作。
enum StoryEventAction: String, Codable, Equatable, Hashable {
    case start
    case continueEvent = "continue"
    case resolve
    case abandon
}

/// STATE_UPDATEの中に任意で含めるイベント差分。
/// actionやsummaryが壊れていても、同じJSON内の通常のStoryState更新を
/// 失わないよう、デコードはこの型の内部で寛容に行う。
struct StoryEventUpdate: Codable, Equatable, Hashable {
    var action: StoryEventAction?
    var summary: String?

    init(action: StoryEventAction? = nil, summary: String? = nil) {
        self.action = action
        self.summary = summary
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case summary
    }

    init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            action = nil
            summary = nil
            return
        }
        if let raw = try? container.decode(String.self, forKey: .action) {
            action = StoryEventAction(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        } else {
            action = nil
        }
        summary = try? container.decode(String.self, forKey: .summary)
    }
}

/// StorySessionに保存する出来事の履歴。本文やユーザーの操作を代行する
/// データではなく、会話の流れを次のターンへ渡すための短い記録だけを持つ。
struct StoryEvent: Codable, Equatable, Hashable, Identifiable {
    var id: UUID
    var summary: String
    var status: StoryEventStatus
    var startMessageID: UUID
    var generationID: UUID
    var aiResponseTurnCount: Int
    var startedAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        summary: String,
        status: StoryEventStatus = .active,
        startMessageID: UUID,
        generationID: UUID,
        aiResponseTurnCount: Int = 1,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.summary = summary
        self.status = status
        self.startMessageID = startMessageID
        self.generationID = generationID
        self.aiResponseTurnCount = aiResponseTurnCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
}

struct StoryEventTransition: Equatable, Hashable {
    let action: StoryEventAction
    let eventID: UUID
}

/// イベントの発生間隔とライフサイクルをアプリ側で決める純粋なReducer。
/// 本番値をここへ集約し、テストでは短い固定値を注入できるようにする。
struct StoryEventPolicy: Equatable, Hashable {
    static let production = StoryEventPolicy(
        initialDelayUserTurns: 5,
        retryDelayUserTurns: 2,
        cooldownUserTurns: 5,
        maxAIResponseTurns: 3,
        historyLimit: 8
    )

    let initialDelayUserTurns: Int
    let retryDelayUserTurns: Int
    let cooldownUserTurns: Int
    let maxAIResponseTurns: Int
    let historyLimit: Int

    func userTurnCount(in session: StorySession) -> Int {
        session.messages.reduce(into: 0) { count, message in
            if message.author.isUser { count += 1 }
        }
    }

    /// 一般的な「次の場面へ」「場所を変える」入力はユーザー自身の
    /// 展開指示なので、モデルに自然発生イベントを重ねさせない。
    func isUserDirectedSceneChange(_ input: String) -> Bool {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard !normalized.isEmpty else { return false }
        let markers = [
            "場面を変", "シーンを変", "場所を変", "場所を移", "移動する",
            "次のシーン", "時間を進", "場面転換", "scene change", "change scene",
            "move to", "next scene", "skip to"
        ]
        return markers.contains { normalized.contains($0) }
    }

    /// 会話開始から数ターン後にだけ、モデルへイベント候補を許可する。
    /// nextSpontaneousEventUserTurnがない旧データは、導入後に少なくとも
    /// initialDelayUserTurns回のユーザー発言を待つ。
    func isEligible(session: StorySession, userInput: String) -> Bool {
        guard activeEvent(in: session) == nil,
              !isUserDirectedSceneChange(userInput) else { return false }
        let turns = userTurnCount(in: session)
        let next = session.nextSpontaneousEventUserTurn
            ?? max(initialDelayUserTurns, turns + initialDelayUserTurns - 1)
        return turns >= next
    }

    func activeEvent(in session: StorySession) -> StoryEvent? {
        session.spontaneousEvents?.last(where: { $0.status == .active })
    }

    /// 成功した通常ターンの最後に一度だけ呼ぶ。生成失敗・安全停止・
    /// 保存失敗の経路からは呼ばれないため、壊れたターンをイベントへ昇格しない。
    @discardableResult
    func apply(
        update: StoryEventUpdate?,
        to session: inout StorySession,
        userMessageID: UUID,
        generationID: UUID,
        userInput: String,
        now: Date = Date()
    ) -> StoryEventTransition? {
        var events = session.spontaneousEvents ?? []
        let userTurns = userTurnCount(in: session)

        if let activeIndex = events.lastIndex(where: { $0.status == .active }) {
            let eventID = events[activeIndex].id
            if isUserDirectedSceneChange(userInput) {
                events[activeIndex].status = .abandoned
                events[activeIndex].updatedAt = now
                session.spontaneousEvents = Array(events.suffix(historyLimit))
                session.nextSpontaneousEventUserTurn = userTurns + cooldownUserTurns
                return StoryEventTransition(action: .abandon, eventID: eventID)
            }

            guard let action = update?.action else {
                events[activeIndex].status = .abandoned
                events[activeIndex].updatedAt = now
                session.spontaneousEvents = Array(events.suffix(historyLimit))
                session.nextSpontaneousEventUserTurn = userTurns + cooldownUserTurns
                return StoryEventTransition(action: .abandon, eventID: eventID)
            }

            switch action {
            case .continueEvent:
                if let summary = normalizedSummary(update?.summary) {
                    events[activeIndex].summary = summary
                }
                events[activeIndex].aiResponseTurnCount += 1
                events[activeIndex].updatedAt = now
                if events[activeIndex].aiResponseTurnCount >= maxAIResponseTurns {
                    events[activeIndex].status = .resolved
                    session.nextSpontaneousEventUserTurn = userTurns + cooldownUserTurns
                    session.spontaneousEvents = Array(events.suffix(historyLimit))
                    return StoryEventTransition(action: .resolve, eventID: eventID)
                }
                session.spontaneousEvents = Array(events.suffix(historyLimit))
                return StoryEventTransition(action: .continueEvent, eventID: eventID)

            case .resolve:
                if let summary = normalizedSummary(update?.summary) {
                    events[activeIndex].summary = summary
                }
                events[activeIndex].status = .resolved
                events[activeIndex].updatedAt = now
                session.spontaneousEvents = Array(events.suffix(historyLimit))
                session.nextSpontaneousEventUserTurn = userTurns + cooldownUserTurns
                return StoryEventTransition(action: .resolve, eventID: eventID)

            case .abandon, .start:
                // start中の別イベントや、既存イベントを上書きする操作は
                // 受理しない。今回の応答で触れられなかったものとして閉じる。
                events[activeIndex].status = .abandoned
                events[activeIndex].updatedAt = now
                session.spontaneousEvents = Array(events.suffix(historyLimit))
                session.nextSpontaneousEventUserTurn = userTurns + cooldownUserTurns
                return StoryEventTransition(action: .abandon, eventID: eventID)
            }
        }

        if session.nextSpontaneousEventUserTurn == nil {
            session.nextSpontaneousEventUserTurn = max(
                initialDelayUserTurns,
                userTurns + initialDelayUserTurns - 1
            )
        }

        guard isEligible(session: session, userInput: userInput) else { return nil }
        guard update?.action == .start,
              let summary = normalizedSummary(update?.summary),
              !isDuplicate(summary: summary, in: events) else {
            session.nextSpontaneousEventUserTurn = userTurns + retryDelayUserTurns
            session.spontaneousEvents = Array(events.suffix(historyLimit))
            return nil
        }

        let event = StoryEvent(
            summary: summary,
            startMessageID: userMessageID,
            generationID: generationID,
            startedAt: now,
            updatedAt: now
        )
        events.append(event)
        session.spontaneousEvents = Array(events.suffix(historyLimit))
        session.nextSpontaneousEventUserTurn = nil
        return StoryEventTransition(action: .start, eventID: event.id)
    }

    func promptInstruction(
        for session: StorySession,
        userInput: String,
        isEnglish: Bool
    ) -> String {
        if isUserDirectedSceneChange(userInput) {
            return isEnglish
                ? "Do not start or continue a spontaneous event on this turn; follow the user's requested scene change."
                : "このターンでは自然発生イベントを開始・継続せず、ユーザーが指定した場面転換を優先します。"
        }
        if let active = activeEvent(in: session) {
            let summary = String(active.summary.prefix(120))
            return isEnglish
                ? "A short spontaneous event is active: \(summary). Only when the user's current message clearly responds to it, append hidden STATE_UPDATE JSON with eventUpdate action continue or resolve. If the user changes topic, omit eventUpdate. Do not explain this rule or turn it into a quest."
                : "短い自然発生イベントが進行中です: \(summary)。今回のユーザー発言が明確にそれへ反応した時だけ、本文の後に隠しSTATE_UPDATE JSONでeventUpdateのactionをcontinueまたはresolveにします。話題が変わったらeventUpdateを付けず、クエストや説明にしません。"
        }

        guard isEligible(session: session, userInput: userInput) else {
            return isEnglish
                ? "Do not start a spontaneous event on this turn."
                : "このターンでは自然発生イベントを開始しません。"
        }

        let recent = (session.spontaneousEvents ?? [])
            .suffix(3)
            .map { String($0.summary.prefix(60)) }
            .joined(separator: " / ")
        let avoid = recent.isEmpty
            ? ""
            : (isEnglish ? " Avoid repeating these recent events: \(recent)." : " 最近の出来事と同じ内容を繰り返しません: \(recent)。")
        return isEnglish
            ? "A spontaneous event may start only when a secret, promise, conflict, character goal, or world detail naturally changes in this conversation. If so, append hidden STATE_UPDATE JSON with eventUpdate {\"action\":\"start\",\"summary\":\"short\"}. Do not invent an unrelated incident, choices, or a quest.\(avoid)"
            : "この会話の秘密・約束・葛藤・人物の目的・世界設定に自然な変化が生まれた時だけ、短い自然発生イベントを開始できます。その場合だけ本文の後に隠しSTATE_UPDATE JSONでeventUpdate {\"action\":\"start\",\"summary\":\"短い要約\"}を付けます。無関係な事件、選択肢、クエストは作りません。\(avoid)"
    }

    private func normalizedSummary(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(160))
    }

    private func isDuplicate(summary: String, in events: [StoryEvent]) -> Bool {
        let normalized = summary
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return true }
        return events.contains { event in
            let previous = event.summary
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            return previous == normalized
        }
    }
}

extension StorySession {
    var activeSpontaneousEvent: StoryEvent? {
        spontaneousEvents?.last(where: { $0.status == .active })
    }
}
