/*
仕様:
- 役割: AI Studio / 子ども用AI / 保護者用AI の保存キー互換を吸収する橋。推論設定、スレッド、Web Search、ローカルモデル設定を旧別名キーとも同期する。
- 主な型: `AILegacyCompatibility`.
- 編集ポイント: AI関連の保存キーや別名キーが増減したときに更新する。
*/

import Foundation

enum AILegacyCompatibility {
    private static let maxUserDefaultsDataBytes = 3_500_000

    static let childAgeAliases = [
        "viuk.ai.childAge",
        "aiStudioChildAge"
    ]

    static let filterLevelAliases = [
        "viuk.ai.filterLevel",
        "aiStudioFilterLevel"
    ]

    static let memoryNoteAliases = [
        "viuk.ai.memoryNote",
        "aiStudioMemoryNote"
    ]

    static let reasoningModeAliases = [
        "viuk.ai.reasoningMode",
        "aiStudioReasoningMode"
    ]

    static let researchModeAliases = [
        "viuk.ai.researchMode",
        "aiStudioResearchMode"
    ]

    static let thinkingLevelAliases = [
        "viuk.ai.thinkingLevel",
        "aiStudioThinkingLevel"
    ]

    static let thoughtTimelineAliases = [
        "viuk.ai.showThoughtTimeline",
        "aiStudioShowThoughtTimeline"
    ]

    static func systemPromptAliases(for modeRawValue: String) -> [String] {
        [
            "viuk.ai.systemPrompt.\(modeRawValue)",
            "aiStudioSystemPrompt.\(modeRawValue)"
        ]
    }

    static let webSearchEnabledAliases = [
        "viuk.ai.ollama.enabled",
        "aiStudioOllamaWebSearchEnabled"
    ]

    static let webSearchAPIKeyAliases = [
        "viuk.ai.ollama.apiKey",
        "aiStudioOllamaWebSearchAPIKey"
    ]

    static let geminiAPIKeyAliases = [
        "viuk.ai.gemini.apiKey",
        "aiStudioGeminiAPIKey",
        "aiCoachGeminiAPIKey",
        "googleGeminiAPIKey",
        "remoteGeminiAPIKey",
        "GEMINI_API_KEY"
    ]

    static let gemmaWebReaderAPIKeyAliases = [
        "viuk.ai.gemma.apiKey",
        "viuk.ai.gemma.webReader.apiKey",
        "aiStudioGemmaAPIKey",
        "aiStudioGemma4APIKey",
        "aiStudioGemmaWebReaderAPIKey",
        "gemmaWebReaderAPIKey",
        "gemmaAPIKey",
        "GEMMA_API_KEY",
        "GOOGLE_API_KEY"
    ]

    static let localModelSourceAliases = [
        "viuk.ai.localModel.sourceURL",
        "aiStudioLocalModelSourceURL"
    ]

    static let localModelInstalledFileAliases = [
        "viuk.ai.localModel.installedFileName",
        "aiStudioLocalModelInstalledFileName"
    ]

    static let localModelTokenAliases = [
        "viuk.ai.localModel.accessToken",
        "aiStudioLocalModelAccessToken"
    ]

    static func chatThreadsAliases(for modeRawValue: String) -> [String] {
        [
            "viuk.ai.chatThreads.\(modeRawValue)",
            "aiStudioChatThreads.\(modeRawValue)"
        ]
    }

    static func currentThreadAliases(for modeRawValue: String) -> [String] {
        [
            "viuk.ai.currentThread.\(modeRawValue)",
            "aiStudioCurrentThread.\(modeRawValue)"
        ]
    }

    static func chatHistoryAliases(for modeRawValue: String, threadID: String) -> [String] {
        [
            "viuk.ai.chatHistory.\(modeRawValue).\(threadID)",
            "aiStudioChatHistory.\(modeRawValue).\(threadID)"
        ]
    }

    static func conversationMemoryAliases(for modeRawValue: String) -> [String] {
        [
            "viuk.ai.conversationMemory.\(modeRawValue)",
            "aiStudioConversationMemory.\(modeRawValue)"
        ]
    }

    static func thoughtSignatureAliases(for modeRawValue: String, threadID: String) -> [String] {
        [
            "viuk.ai.thoughtSignatures.\(modeRawValue).\(threadID)",
            "aiStudioThoughtSignatures.\(modeRawValue).\(threadID)"
        ]
    }

    static func stringValue(
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) -> String? {
        if let primaryKey, let value = defaults.string(forKey: primaryKey) {
            return value
        }

        for key in aliases {
            if let value = defaults.string(forKey: key) {
                return value
            }
        }

        return nil
    }

    static func boolValue(
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) -> Bool? {
        if let primaryKey, defaults.object(forKey: primaryKey) != nil {
            return defaults.bool(forKey: primaryKey)
        }

        for key in aliases where defaults.object(forKey: key) != nil {
            return defaults.bool(forKey: key)
        }

        return nil
    }

    static func intValue(
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) -> Int? {
        if let primaryKey, defaults.object(forKey: primaryKey) != nil {
            return defaults.integer(forKey: primaryKey)
        }

        for key in aliases where defaults.object(forKey: key) != nil {
            return defaults.integer(forKey: key)
        }

        return nil
    }

    static func dataValue(
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) -> Data? {
        if let primaryKey, let value = defaults.data(forKey: primaryKey) {
            return value
        }

        for key in aliases {
            if let value = defaults.data(forKey: key) {
                return value
            }
        }

        return nil
    }

    static func stringArrayValue(
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) -> [String]? {
        if let primaryKey, let value = defaults.stringArray(forKey: primaryKey) {
            return value
        }

        for key in aliases {
            if let value = defaults.stringArray(forKey: key) {
                return value
            }
        }

        return nil
    }

    static func exportString(
        _ value: String,
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) {
        if let primaryKey {
            defaults.set(value, forKey: primaryKey)
        }
        for key in aliases {
            defaults.set(value, forKey: key)
        }
    }

    static func exportBool(
        _ value: Bool,
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) {
        if let primaryKey {
            defaults.set(value, forKey: primaryKey)
        }
        for key in aliases {
            defaults.set(value, forKey: key)
        }
    }

    static func exportInt(
        _ value: Int,
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) {
        if let primaryKey {
            defaults.set(value, forKey: primaryKey)
        }
        for key in aliases {
            defaults.set(value, forKey: key)
        }
    }

    static func exportData(
        _ value: Data,
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) {
        guard value.count < maxUserDefaultsDataBytes else {
            #if DEBUG
            NSLog(
                "[AILegacyCompatibility] skipped oversized UserDefaults Data write: bytes=%d primary=%@ aliases=%d",
                value.count,
                primaryKey ?? "(none)",
                aliases.count
            )
            #endif
            removeValue(primaryKey: primaryKey, aliases: aliases, defaults: defaults)
            return
        }
        if let primaryKey {
            defaults.set(value, forKey: primaryKey)
        }
        for key in aliases {
            defaults.set(value, forKey: key)
        }
    }

    static func exportStringArray(
        _ value: [String],
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) {
        if let primaryKey {
            defaults.set(value, forKey: primaryKey)
        }
        for key in aliases {
            defaults.set(value, forKey: key)
        }
    }

    static func removeValue(
        primaryKey: String? = nil,
        aliases: [String],
        defaults: UserDefaults = .standard
    ) {
        if let primaryKey {
            defaults.removeObject(forKey: primaryKey)
        }
        for key in aliases {
            defaults.removeObject(forKey: key)
        }
    }
}
