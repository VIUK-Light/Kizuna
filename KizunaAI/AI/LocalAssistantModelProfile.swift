/*
仕様:
- 役割: VIUK One が採用したローカルAIモデルの名称、能力、UI表示文言を一元管理する。
- 主な型: `LocalAssistantModelProfile`.
- 編集ポイント: オフラインモデル名、量子化表記、対応能力、ハイブリッド表示を変えるときに触る。
*/
import Foundation

enum LocalAssistantModelProfile {
    struct RuntimePreset {
        let contextSize: Int
        let batchSize: Int
        let microBatchSize: Int
        let threadCount: Int
        let batchThreadCount: Int
        let gpuLayers: Int
        let flashAttentionEnabled: Bool
        let disableKVOffload: Bool
    }

    struct GenerationPreset {
        let maxTokens: Int
        let temperature: Float
        let topP: Float
        let topK: Int
        let seed: UInt32
    }

    static let modelName = "VIUK AI tiny"

    #if os(iOS)
    private static let defaultInternalModelName = "Gemma 4 E2B LiteRT-LM"
    private static let defaultCapabilitySummary = "LiteRT-LM / スマホ高速推論優先 / 低メモリ"
    private static let defaultModelURL = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true"
    private static let defaultModelFileName = "gemma-4-E2B-it.litertlm"
    private static let defaultStorageFolderName = "Gemma4E2BLiteRTLM"
    private static let defaultExpectedModelSizeBytes: Int64 = 2_588_147_712
    private static let fallbackDefaultDownloadURLs = [
        "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_S.gguf?download=true",
        "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q4_K_XL.gguf?download=true",
        "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-UD-Q4_K_XL.gguf?download=true"
    ]
    #else
    private static let defaultInternalModelName = "Gemma 4 E4B 4bit"
    private static let defaultCapabilitySummary = "4bit量子化 / 推論品質重視 / コードと複数条件に強い"
    private static let defaultModelURL = "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q4_K_XL.gguf?download=true"
    private static let defaultModelFileName = "gemma-4-E4B-it-UD-Q4_K_XL.gguf"
    private static let defaultStorageFolderName = "Gemma4E4B4bit"
    private static let defaultExpectedModelSizeBytes: Int64 = 5_101_713_536
    private static let fallbackDefaultDownloadURLs = [
        "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-UD-Q4_K_XL.gguf?download=true"
    ]
    #endif

    static let internalModelName = defaultInternalModelName
    static let capabilitySummary = defaultCapabilitySummary
    static let offlineLabel = modelName
    static let hybridLabel = "VIUK AI"
    static let defaultDownloadLabel = "\(internalModelName) 標準リンク"
    static let defaultDownloadURL = defaultModelURL
    static let legacyDefaultDownloadURLs = fallbackDefaultDownloadURLs
    static let defaultFileName = defaultModelFileName
    static let storageFolderName = defaultStorageFolderName
    static let legacyFolderNames = ["Gemma4E2B4bit", "Gemma4E4B4bit", "Gemma3nE4B4bit", "VIUKAItiny", "VIUK AI tiny"]
    static let expectedModelSizeBytes: Int64 = defaultExpectedModelSizeBytes
    static let minimumAcceptedModelSizeBytes: Int64 = 50 * 1024 * 1024

    private static let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    private static let prefersAggressiveGPUOffload = physicalMemoryBytes >= 15 * 1024 * 1024 * 1024
    private static let runtimeGPULayerCount = prefersAggressiveGPUOffload ? 99 : 12
    private static let prewarmGPULayerCount = prefersAggressiveGPUOffload ? 24 : 4

    // 通常実行 preset（thinking / deepThinking モード向け）
    // M2 16GB など統合メモリ機では 8192 ctx でも KV キャッシュは ~600MB 程度に収まる
    static let runtimePreset = RuntimePreset(
        contextSize: 8192,
        batchSize: prefersAggressiveGPUOffload ? 512 : 128,
        microBatchSize: prefersAggressiveGPUOffload ? 128 : 32,
        threadCount: min(max(ProcessInfo.processInfo.activeProcessorCount - 2, 4), 8),
        batchThreadCount: prefersAggressiveGPUOffload ? 4 : min(max(ProcessInfo.processInfo.activeProcessorCount / 4, 1), 2),
        gpuLayers: runtimeGPULayerCount,
        flashAttentionEnabled: prefersAggressiveGPUOffload,
        disableKVOffload: false
    )

    // fast モード専用 preset: ctx を 4096 にして KV キャッシュを抑えつつ、
    // batchSize を最大化してプリフィル速度を向上
    static let fastRuntimePreset = RuntimePreset(
        contextSize: 4096,
        batchSize: prefersAggressiveGPUOffload ? 512 : 256,
        microBatchSize: prefersAggressiveGPUOffload ? 128 : 64,
        threadCount: min(max(ProcessInfo.processInfo.activeProcessorCount - 1, 4), 8),
        batchThreadCount: prefersAggressiveGPUOffload ? 4 : min(max(ProcessInfo.processInfo.activeProcessorCount / 4, 1), 2),
        gpuLayers: prefersAggressiveGPUOffload ? 99 : min(runtimeGPULayerCount + 6, 24),
        flashAttentionEnabled: prefersAggressiveGPUOffload,
        disableKVOffload: false
    )

    static let prewarmRuntimePreset = RuntimePreset(
        contextSize: 1024,
        batchSize: prefersAggressiveGPUOffload ? 64 : 16,
        microBatchSize: prefersAggressiveGPUOffload ? 16 : 4,
        threadCount: min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 4),
        batchThreadCount: 1,
        gpuLayers: prewarmGPULayerCount,
        flashAttentionEnabled: prefersAggressiveGPUOffload,
        disableKVOffload: false
    )

    static let prewarmReadAheadBytes: Int64 = 256 * 1024 * 1024
    static let prewarmTimeoutSeconds: Int = 45

    static let freeAccessDescription = "\(modelName) のローカル案内"
    static let standardAccessDescription = "VIUK AI の高精度補助つき"
    static let premiumAccessDescription = "VIUK AI の高精度補助を無制限で利用"

    static let freePlanFeature = "AIコーチ: \(modelName) で利用可能"
    static let standardPlanFeature = "AIコーチ: VIUK AI の高精度補助つき"

    static func generationPreset(
        for reasoningMode: ReasoningMode,
        researchMode: ResearchMode = .on
    ) -> GenerationPreset {
        // maxTokens 設計:
        // - Fast モードは Perplexity Sonar 体感を狙うため 384〜512 トークンに圧縮
        //   (M2 16GB + GPU フルオフロードで ~40 tok/s なので 384 ≈ 9.6 秒、512 ≈ 12.8 秒)
        // - Thinking / DeepThinking は Gemma 4 native thinking が内部推論で
        //   1000〜5000 トークン消費するため、回答分を確保するには十分な上限が必要。
        //   8k でも thinking + 本文で詰まるケースがあるため、Thinking 以上はさらに余裕を持たせる。
        //   参考: DeepSeek R1 / QwQ-32B など他 thinking モデルも 8k〜16k を推奨。
        //   コンテキストは effectiveCLITuning で 12_288 を確保している。
        switch (reasoningMode, researchMode) {
        case (.fast, .deep):
            // Deep 研究モードでは引用・要約が多いので Sonar より少しだけ余裕を持たせる
            return GenerationPreset(maxTokens: 512, temperature: 0.15, topP: 0.74, topK: 20, seed: 21)
        case (.fast, _):
            // Sonar スタイル: 結論先行 + 1〜2 文補足のみ。ハードキャップで体感速度を確保
            return GenerationPreset(maxTokens: 384, temperature: 0.14, topP: 0.70, topK: 16, seed: 21)
        case (.thinking, .deep):
            // Deep + thinking は検索結果踏まえた長文を出すため最大確保
            return GenerationPreset(maxTokens: 14_336, temperature: 0.42, topP: 0.88, topK: 40, seed: 22)
        case (.thinking, _):
            // 通常 thinking: 思考 ~4000 + 回答 ~5000 を見込んで 12k 確保
            return GenerationPreset(maxTokens: 12_288, temperature: 0.44, topP: 0.88, topK: 40, seed: 22)
        case (.deepThinking, .deep):
            // Deep + DeepThinking は最長: 思考 ~5000 + 検索踏まえた回答 ~5000
            return GenerationPreset(maxTokens: 16_384, temperature: 0.48, topP: 0.9, topK: 48, seed: 23)
        case (.deepThinking, _):
            return GenerationPreset(maxTokens: 14_336, temperature: 0.5, topP: 0.9, topK: 48, seed: 23)
        case (.persona, _):
            // 恋愛モード: 短文・自然な会話。temperature は少し高めにして表現を柔らかく。
            return GenerationPreset(maxTokens: 256, temperature: 0.55, topP: 0.85, topK: 40, seed: 24)
        }
    }

    static func supportBriefPreset(for reasoningMode: ReasoningMode) -> GenerationPreset {
        switch reasoningMode {
        case .fast, .persona:
            return GenerationPreset(maxTokens: 96, temperature: 0.12, topP: 0.72, topK: 18, seed: 31)
        case .thinking:
            return GenerationPreset(maxTokens: 192, temperature: 0.22, topP: 0.82, topK: 30, seed: 32)
        case .deepThinking:
            return GenerationPreset(maxTokens: 240, temperature: 0.24, topP: 0.84, topK: 32, seed: 33)
        }
    }
}
