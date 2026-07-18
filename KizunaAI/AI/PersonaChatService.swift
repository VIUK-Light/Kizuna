/*
仕様:
- 役割: ペルソナチャットの送信・ストリーミング受信・履歴更新を担う。AICoachService とは独立し、
  ペルソナモードの会話だけを扱う。バックエンドは LocalAssistantRuntimeBridge.generateReply を
  reasoningMode: .persona で呼び出す。
- 主な型: `PersonaChatService` (ObservableObject, MainActor)。
- 編集ポイント: 履歴の渡し方、max_tokens、ストリーミング差分の扱い、安全用 advancedSettings を変えるときに触る。
*/

import Foundation
import Combine

@MainActor
final class PersonaChatService: ObservableObject {
    static let shared = PersonaChatService()

    enum Phase: Equatable {
        case idle
        case thinking
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// ストリーミング中の最新応答テキスト。完了時に PersonaChatStore に永続化される。
    @Published private(set) var streamingResponse: String = ""

    private var generationTask: Task<Void, Never>?
    private var lastVisibleText: String = ""
    private var activeGenerationID: UUID?

    private init() {}

    /// 指定スレッドにユーザー発話を追加し、Gemma 4 のペルソナモードで応答を生成する。
    // MARK: - DI for Character Library pipeline (default: Local + Mock)
    /// 既存挙動を壊さないために、スレッドに characterID が紐付いている場合だけ使う。
    private let characterRepo: CharacterRepository = LocalJSONCharacterRepository()
    private let memoryRepo: MemoryRepository = LocalJSONMemoryRepository()
    private let safetyPipeline = SafetyPipeline.shared
    private let smallClassifier: SmallModelClassifying = MockSmallModelClassifier()
    private let memorySelector: MemorySelecting = MockMemorySelector()
    private let memorySummarizer: MemorySummarizing = MockMemorySummarizer()
    private let promptBuilder = PromptBuilder()

    func send(_ userText: String, to thread: PersonaThread) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard phase != .thinking else { return }

        // ユーザーメッセージ & 空のアシスタントメッセージを追加 (アシスタント側はストリームで埋める)
        PersonaChatStore.shared.appendMessage(
            PersonaMessage(role: .user, text: trimmed),
            toThread: thread.id
        )
        PersonaChatStore.shared.appendMessage(
            PersonaMessage(role: .assistant, text: ""),
            toThread: thread.id
        )

        // スレッドスナップショットの persona をブリッジに反映 (overrideSystemPrompt を使わない経路で必要)
        LocalAssistantRuntimeBridge.personaAddendum = thread.personaSnapshot.promptText

        phase = .thinking
        streamingResponse = ""
        lastVisibleText = ""
        let generationID = UUID()
        activeGenerationID = generationID

        if let charID = thread.characterID {
            // 新パス: キャラライブラリー由来のスレッド → 安全 + メモリーパイプライン
            generationTask = Task { [weak self] in
                await self?.runCharacterPipeline(threadID: thread.id, characterID: charID, userText: trimmed, generationID: generationID)
            }
        } else {
            // 旧パス: PersonaSettings 由来のスレッド → 既存ストリーミングのまま
            LocalAssistantRuntimeBridge.kizunaActiveMemories = []
            let composedPrompt = buildPrompt(forThread: thread, latestUser: trimmed)
            let advanced = voiceOptimizedAdvancedSettings
            generationTask = Task { [weak self, threadID = thread.id] in
                guard let self else { return }
                let bridge = LocalAssistantRuntimeBridge.shared
                let reply = await bridge.generateReply(
                    prompt: composedPrompt,
                    contextPrompt: nil,
                    coachMode: .studio,
                    reasoningMode: .persona,
                    researchMode: .off,
                    childAge: 12,
                    pageInfo: nil,
                    safetySnapshot: nil,
                    advancedSettings: advanced,
                    onUpdate: { @MainActor [weak self] update in
                        self?.handleStreamUpdate(update, threadID: threadID, generationID: generationID)
                    }
                )
                await MainActor.run {
                    self.finalize(reply: reply, threadID: threadID, generationID: generationID)
                }
            }
        }
        startWatchdog(threadID: thread.id, generationID: generationID)
    }

    func addNarration(_ text: String, to thread: PersonaThread) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        PersonaChatStore.shared.appendMessage(
            PersonaMessage(role: .narrator, text: trimmed),
            toThread: thread.id
        )
        PersonaChatStore.shared.finalizePersist()
    }

    /// CharacterLibrary 由来スレッドのフルパイプライン。
    /// 1) 入力 safety → 2) メモリー候補取得 → 3) 270M 分類 + 選別 → 4) PromptBuilder → 5) E4B 生成
    /// → 6) 出力 safety → 7) async でメモリー抽出・保存。
    private func runCharacterPipeline(threadID: UUID, characterID: UUID, userText: String, generationID: UUID) async {
        // ── 1) CharacterProfile / Lorebook 取得 ──
        let allCharacters = (try? await characterRepo.fetchCharacters()) ?? []
        guard let character = allCharacters.first(where: { $0.id == characterID }) else {
            // キャラが消えていた → 旧パスにフォールバック
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                self.phase = .error("キャラ情報が見つかりませんでした。")
            }
            return
        }
        let lorebook = try? await characterRepo.fetchLorebook(characterId: characterID)

        // ── 2) 入力 safety ──
        let inSafety = await safetyPipeline.evaluateInput(userText, character: character)
        if inSafety.action == .block {
            // ブロックされたらキャラから穏当な拒否メッセージを返して終了
            let polite = inSafety.rewrittenText ?? "ごめん、その話題には乗れないな。別の話、しよ?"
            await MainActor.run {
                guard self.activeGenerationID == generationID else { return }
                PersonaChatStore.shared.updateLastAssistantMessage(in: threadID, text: polite)
                PersonaChatStore.shared.finalizePersist()
                self.streamingResponse = polite
                self.phase = .idle
                self.activeGenerationID = nil
            }
            return
        }
        let effectiveUserText = inSafety.rewrittenText ?? userText

        // ── 3) メモリー候補と選別 ──
        let candidates = (try? await memoryRepo.fetchMemories(characterId: characterID)) ?? []
        let needsRecall: Bool
        if candidates.isEmpty {
            needsRecall = false
        } else {
            let c = await smallClassifier.classify(
                text: effectiveUserText,
                labels: ["recall_needed", "casual_chat"]
            )
            needsRecall = (c.label == "recall_needed" && c.confidence > 0.35) || candidates.count <= 3
        }
        let selected: [CharacterMemory]
        if needsRecall {
            if candidates.count > 5 {
                selected = await memorySelector.select(query: effectiveUserText, candidates: candidates, topK: 5)
            } else {
                selected = candidates
            }
        } else {
            selected = []
        }

        // 想起したメモリーは lastUsedAt 更新
        if !selected.isEmpty {
            try? await memoryRepo.markUsed(ids: selected.map(\.id))
        }
        LocalAssistantRuntimeBridge.kizunaActiveMemories = selected.map(\.text)

        // ── 4) PromptBuilder ──
        let recent = await MainActor.run { () -> [PersonaMessage] in
            (PersonaChatStore.shared.threads.first(where: { $0.id == threadID })?.messages ?? [])
                .filter { !($0.role == .assistant && $0.text.isEmpty) }
                .suffix(6)
                .map { $0 }
        }
        let systemPrompt = promptBuilder.build(
            character: character,
            lorebook: lorebook,
            selectedMemories: selected,
            recentMessages: recent,
            userInput: effectiveUserText,
            safetyDecision: inSafety
        )

        // ── 5) E4B 生成 (overrideSystemPrompt 経路) ──
        let advanced = voiceOptimizedAdvancedSettings
        let bridge = LocalAssistantRuntimeBridge.shared
        let reply = await bridge.generateReply(
            prompt: effectiveUserText,
            contextPrompt: nil,
            coachMode: .studio,
            reasoningMode: .persona,
            researchMode: .off,
            childAge: 12,
            pageInfo: nil,
            safetySnapshot: nil,
            advancedSettings: advanced,
            overrideSystemPrompt: systemPrompt,
            onUpdate: { @MainActor [weak self] update in
                self?.handleStreamUpdate(update, threadID: threadID, generationID: generationID)
            }
        )

        // ── 6) 出力 safety ──
        var finalText = (reply?.isEmpty == false ? reply! : streamingResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        finalText = sanitizedFinalText(finalText)
        let outSafety = await safetyPipeline.evaluateOutput(finalText, character: character)
        switch outSafety.action {
        case .block:
            finalText = outSafety.rewrittenText ?? "うまく言えないけど、それは話したくないな。別の話にしよう?"
        case .soften, .requireEdit:
            if let rewritten = outSafety.rewrittenText, !rewritten.isEmpty {
                finalText = rewritten
            }
        case .warn, .allow:
            break
        }

        await MainActor.run {
            guard self.activeGenerationID == generationID else { return }
            self.streamingResponse = finalText
            PersonaChatStore.shared.updateLastAssistantMessage(in: threadID, text: finalText)
            PersonaChatStore.shared.finalizePersist()
            self.phase = .idle
            self.activeGenerationID = nil
        }

        // ── 7) メモリー抽出 (UI を idle にした後に await。中断されても致命的ではない) ──
        let newMemories = await memorySummarizer.extract(
            userText: userText,
            assistantText: finalText,
            character: character
        )
        for m in newMemories {
            try? await memoryRepo.saveMemory(m)
        }
    }

    func cancel() {
        generationTask?.cancel()
        LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
        activeGenerationID = nil
        phase = .idle
    }

    // MARK: - Streaming

    private func handleStreamUpdate(_ update: LocalAssistantStructuredTurnUpdate, threadID: UUID, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        guard case let .visiblePreview(text) = update else { return }
        let stripped = sanitize(text)
        if stripped.count < lastVisibleText.count {
            // リセット系の更新が来た場合は最新値で上書き
            lastVisibleText = stripped
        } else {
            lastVisibleText = stripped
        }
        streamingResponse = stripped
        PersonaChatStore.shared.updateLastAssistantMessage(in: threadID, text: stripped)
    }

    private func finalize(reply: String?, threadID: UUID, generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        let final = (reply?.isEmpty == false ? reply! : streamingResponse)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = sanitizedFinalText(final)
        streamingResponse = cleaned
        PersonaChatStore.shared.updateLastAssistantMessage(in: threadID, text: cleaned)
        PersonaChatStore.shared.finalizePersist()
        phase = .idle
        activeGenerationID = nil
    }

    private func startWatchdog(threadID: UUID, generationID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 75_000_000_000)
            await MainActor.run {
                guard let self,
                      self.activeGenerationID == generationID,
                      self.phase == .thinking else { return }
                LocalAssistantRuntimeBridge.shared.cancelActiveGeneration()
                let fallback = self.streamingResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "（応答が止まったため中断しました。もう一度送ってください）"
                    : self.streamingResponse
                PersonaChatStore.shared.updateLastAssistantMessage(in: threadID, text: fallback)
                PersonaChatStore.shared.finalizePersist()
                self.streamingResponse = fallback
                self.phase = .idle
                self.activeGenerationID = nil
            }
        }
    }

    // MARK: - Prompt assembly

    private func buildPrompt(forThread thread: PersonaThread, latestUser: String) -> String {
        // 履歴は最新 6 メッセージ程度に絞り、レイテンシを抑える。
        let recent = thread.messages.suffix(6)
        var lines: [String] = []
        for msg in recent {
            switch msg.role {
            case .user:
                lines.append("相手: " + msg.text)
            case .assistant:
                if !msg.text.isEmpty {
                    lines.append("\(thread.personaSnapshot.name): " + msg.text)
                }
            case .narrator:
                if !msg.text.isEmpty {
                    lines.append("ナレーション: " + msg.text)
                }
            }
        }
        if lines.last != "相手: " + latestUser {
            lines.append("相手: " + latestUser)
        }
        // 末尾でキャラ名 + ":" でプライム。これにより Gemma 4 は
        // 「\(name): 」の直後にメッセージ本体を続けざるを得なくなり、
        // 思考文 ("〜について考える") を頭に書く余地が消える。
        lines.append("\(thread.personaSnapshot.name):")
        return lines.joined(separator: "\n")
    }

    private func sanitizedFinalText(_ text: String) -> String {
        let cleaned = sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return "ごめん、少し言葉が詰まった。もう一回だけ聞かせて。"
        }
        if cleaned.count <= 1 {
            return "ごめん、今の返事は短すぎたね。もう少しちゃんと聞かせて。"
        }
        return cleaned
    }

    /// ペルソナ会話用 advancedSettings。ツール/検索を切り、内部システム指示を最小化する。
    private var voiceOptimizedAdvancedSettings: GemmaAdvancedSettings {
        var s = GemmaAdvancedSettings.default
        s.allowToolUsage = false
        s.strictJSONToolCalls = false
        s.allowDirectAnswersWithoutTools = true
        s.requireSearchForFactualQueries = false
        s.requireExternalSourcesInDeepResearch = false
        s.maxToolRounds = 0
        s.maxSearchRounds = 0
        s.enabledTools = [:]
        s.useAutomaticTemperature = true
        return s
    }

    /// Gemma 4 の thinking channel リーク + markdown 記号 + 思考漏れラベルを剥がす。
    private func sanitize(_ text: String) -> String {
        var out = text

        // === Gemma 4 の channel マーカー以前 (=thinking 部分) を削除 ===
        // Gemma 4 は内部で thought / answer のチャンネル切替に
        // `<|channel|>`, `<channel|>`, `<channel>`, `<start_of_turn|>`, `<|start|>` 等の
        // バリアントを出すことがある。マーカーが現れた場合、それ以前は thinking と見なし破棄、
        // マーカー以降を visible として採用する。
        let channelMarkers = [
            "<|channel|>", "<channel|>", "<|channel>", "<channel>",
            "<|message|>", "<message|>", "<|message>", "<message>",
            "<|start_of_turn|>", "<start_of_turn|>", "<|start|>"
        ]
        // 一番最後に現れたマーカーで切る (thinking → answer の最終境界を取る)。
        var lastMarkerEndIndex: String.Index?
        for marker in channelMarkers {
            if let range = out.range(of: marker, options: .backwards) {
                if let existing = lastMarkerEndIndex {
                    if range.upperBound > existing {
                        lastMarkerEndIndex = range.upperBound
                    }
                } else {
                    lastMarkerEndIndex = range.upperBound
                }
            }
        }
        if let endIdx = lastMarkerEndIndex {
            out = String(out[endIdx...])
        }

        // === markdown 記号を剥がす ===
        for token in ["**", "__", "`", "*", "_"] {
            out = out.replacingOccurrences(of: token, with: "")
        }

        // === 計画/実行/分析 などのラベル行 + 番号付き行を削除 ===
        let droppedPrefixes = [
            "計画:", "計画:", "計画：",
            "実行:", "実行:", "実行：",
            "分析:", "分析:", "分析：",
            "内部メモ:", "内部メモ：",
            "ステップ:", "ステップ：",
            "Step:", "step:",
            "Plan:", "plan:",
            "Action:", "action:",
            "以下:", "以下：",
            "(案)", "(案)", "案:", "案：",
            "ユーザーから", "ユーザーは"
        ]
        let lines = out.components(separatedBy: "\n")
        let filtered = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            // 行全体が "1." "2." "1)" などで始まる箇条書きを除外
            if let first = trimmed.first {
                if first.isNumber {
                    let chars = Array(trimmed)
                    if chars.count >= 2 {
                        let second = chars[1]
                        if second == "." || second == ")" || second == "、" || second == ":" || second == "。" {
                            return nil
                        }
                    }
                }
            }
            for prefix in droppedPrefixes {
                if trimmed.hasPrefix(prefix) {
                    return nil
                }
            }
            return line
        }
        out = filtered.joined(separator: "\n")

        // === XML/特殊タグ残りを削除 ===
        // <channel> / <|...|> 系の閉じタグ・断片が残っている場合、除去する。
        let tagPattern = "<\\|?[^>]{0,40}\\|?>"
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
        }

        // === 連続改行/空白を圧縮 + 前後トリム ===
        while out.contains("\n\n") {
            out = out.replacingOccurrences(of: "\n\n", with: "\n")
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)

        // === ナレーション救済: もし結果に三人称ナレーションキーワードが残っていて、
        //     かつ「...」で囲まれた引用が含まれている場合、最後の引用部分だけを採用する ===
        let narrationKeywords = ["として", "考える", "を意識", "を出す", "受け止", "案)", "落とし込", "反応する"]
        let hasNarration = narrationKeywords.contains { out.contains($0) }
        if hasNarration {
            // 「...」または「..." または '...' で囲まれた最終引用を取り出す
            let quotePatterns: [(String, String)] = [
                ("「", "」"),
                ("『", "』"),
                ("\"", "\"")
            ]
            var bestQuote: String?
            for (openQ, closeQ) in quotePatterns {
                if let openRange = out.range(of: openQ, options: .backwards) {
                    let after = out[openRange.upperBound...]
                    if let closeRange = after.range(of: closeQ) {
                        let inner = String(after[..<closeRange.lowerBound])
                        if !inner.isEmpty {
                            bestQuote = inner
                            break
                        }
                    }
                }
            }
            if let q = bestQuote {
                out = q.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }
}
