/*
仕様:
- 役割: VIUK One が採用したローカルAIモデルの名称、能力、UI表示文言を一元管理する。
- 主な型: `LocalAssistantModelProfile`.
- 編集ポイント: オフラインモデル名、量子化表記、対応能力、ハイブリッド表示を変えるときに触る。
*/
import Foundation

enum LocalAssistantModelProfile {
    enum DownloadKind: String, Hashable {
        case viukStoryGGUF
        case gemma4E2BLiteRTLM
        case gemma3nE4BGGUF
    }

    struct DownloadOption: Identifiable, Hashable {
        let kind: DownloadKind
        let title: String
        let url: String
        let detail: String
        let englishDetail: String

        // Keep picker identity stable if a hosting URL or query parameter
        // changes. The model kind, not its transport URL, is the identity.
        var id: String { kind.rawValue }
    }

    /// 標準リンクの配布物は、URLだけでなくサイズとSHA-256も固定する。
    /// リダイレクト先の一時URLではなく、ユーザーが選択したHugging Faceの
    /// resolve URLを照合するため、クエリとfragmentは比較対象から外す。
    struct TrustedArtifact: Hashable, Sendable {
        let sourceURL: String
        let fileName: String
        let byteCount: Int64
        let sha256: String

        nonisolated init(sourceURL: String, fileName: String, byteCount: Int64, sha256: String) {
            self.sourceURL = sourceURL
            self.fileName = fileName
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

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
    private static let defaultInternalModelName = "VIUK Story v2.5 "
    private static let defaultCapabilitySummary = "VIUKによる物語のために開発されたモデル"
    // iOSの既定値はスマホ向けGemma 4 E2B。LiteRT-LMで実行できる本体直リンク。
    private static let defaultModelURL = "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true"
    private static let platformDownloadOptions = [
        DownloadOption(
            kind: .viukStoryGGUF,
            title: "VIUK Story v2.5 GGUF",
            url: "https://huggingface.co/Shirokuma-VIUK/VIUK-Story-v2.5-GGUF/resolve/main/viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf?download=true",
            detail: "Hugging FaceのVIUK標準モデル",
            englishDetail: "VIUK standard model from Hugging Face"
        ),
        DownloadOption(
            kind: .gemma4E2BLiteRTLM,
            title: "Gemma 4 E2B LiteRT-LM",
            url: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true",
            detail: "スマホ向けLiteRT-LM形式。保存後、端末内で自動確認してから利用できます",
            englishDetail: "LiteRT-LM format for phones. The app checks it on-device before use."
        )
    ]
    private static let defaultModelFileName = "gemma-4-E2B-it.litertlm"
    private static let defaultStorageFolderName = "Gemma4E2BLiteRTLM"
    // Gemma 4 E2B LiteRT-LMの配布サイズ目安。
    private static let defaultExpectedModelSizeBytes: Int64 = 2_588_147_712
    #else
    private static let defaultInternalModelName = "Gemma 4 E4B 4bit"
    private static let defaultCapabilitySummary = "4bit量子化 / 推論品質重視 / コードと複数条件に強い"
    // リポジトリページではなく、端末へ保存できるGGUF本体の直リンクを使う。
    private static let defaultModelURL = "https://huggingface.co/Shirokuma-VIUK/VIUK-Story-v2.5-GGUF/resolve/main/viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf?download=true"
    private static let platformDownloadOptions = [
        DownloadOption(
            kind: .viukStoryGGUF,
            title: "VIUK Story v2.5 GGUF",
            url: defaultModelURL,
            detail: "Hugging FaceのVIUK標準モデル",
            englishDetail: "VIUK standard model from Hugging Face"
        ),
        DownloadOption(
            kind: .gemma3nE4BGGUF,
            title: "Gemma 3n E4B GGUF",
            url: "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-UD-Q4_K_XL.gguf?download=true",
            detail: "互換用のGemma 3n 4bit GGUF",
            englishDetail: "Compatible Gemma 3n 4-bit GGUF model"
        )
    ]
    private static let defaultModelFileName = "viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf"
    private static let defaultStorageFolderName = "Gemma4E4B4bit"
    // HF掲載のQ4_K_Mの正確なバイト数。進捗表示だけでなく最終検証にも使う。
    private static let defaultExpectedModelSizeBytes: Int64 = 3_416_118_624
    #endif

    static let internalModelName = defaultInternalModelName
    static let capabilitySummary = defaultCapabilitySummary
    static let offlineLabel = modelName
    static let hybridLabel = "VIUK AI"
    static let defaultDownloadLabel = "\(internalModelName) 標準リンク"
    static let defaultDownloadURL = defaultModelURL
    static let standardDownloadOptions = platformDownloadOptions
    // 以前のリポジトリページURLだけは直リンクへ移行する。Gemmaなどの
    // alternate URLは選択肢として有効なので、旧URL扱いして上書きしない。
    static let legacyDefaultDownloadURLs: [String] = [
        "https://huggingface.co/Shirokuma-VIUK/VIUK-Story-v2.5-GGUF"
    ]
    static let defaultFileName = defaultModelFileName
    static let storageFolderName = defaultStorageFolderName
    static let legacyFolderNames = ["Gemma4E2B4bit", "Gemma4E4B4bit", "Gemma3nE4B4bit", "VIUKAItiny", "VIUK AI tiny"]
    static let expectedModelSizeBytes: Int64 = defaultExpectedModelSizeBytes
    nonisolated static let minimumAcceptedModelSizeBytes: Int64 = 50 * 1024 * 1024

    nonisolated private static let trustedArtifacts: [TrustedArtifact] = [
        TrustedArtifact(
            sourceURL: "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm",
            fileName: "gemma-4-E2B-it.litertlm",
            byteCount: 2_588_147_712,
            sha256: "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
        ),
        TrustedArtifact(
            sourceURL: "https://huggingface.co/Shirokuma-VIUK/VIUK-Story-v2.5-GGUF/resolve/main/viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf",
            fileName: "viuk-story-gemma4-e2b-fullft-hard-identity-Q4_K_M.gguf",
            byteCount: 3_416_118_624,
            sha256: "eafe6431810b2a2a17f6c4b0be338364440707e10ff6648d07665e10875039a5"
        ),
        TrustedArtifact(
            sourceURL: "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-UD-Q4_K_XL.gguf",
            fileName: "gemma-3n-E4B-it-UD-Q4_K_XL.gguf",
            byteCount: 5_385_042_048,
            sha256: "49f8ac599ea6b01e7421ffb584f92f89583224ad5b490d7870e3b4fd503e50eb"
        )
    ]

    nonisolated static func trustedArtifact(for sourceURL: String) -> TrustedArtifact? {
        guard let normalized = canonicalDownloadURL(sourceURL) else { return nil }
        return trustedArtifacts.first {
            canonicalDownloadURL($0.sourceURL) == normalized
        }
    }

    nonisolated private static func canonicalDownloadURL(_ rawURL: String) -> String? {
        guard var components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return nil
        }
        components.scheme = "https"
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    private static let prefersAggressiveGPUOffload = physicalMemoryBytes >= 15 * 1024 * 1024 * 1024
    private static let runtimeGPULayerCount = prefersAggressiveGPUOffload ? 99 : 12
    private static let prewarmGPULayerCount = prefersAggressiveGPUOffload ? 24 : 4

    // 通常実行 preset（thinking / deepThinking モード向け）。
    // 共有ランタイムの既定値は変更せず、Kizuna専用値は下のpersona presetに分離する。
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

    // fast モード専用 preset: ctx を4096にしてKVキャッシュを抑えつつ、
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

    // Kizunaのpersonaモード専用。共有設定を変更せず、
    // 会話履歴だけ長く保持しながらスレッド数は端末負荷を抑える。
    static let personaRuntimePreset = RuntimePreset(
        contextSize: 16_384,
        batchSize: prefersAggressiveGPUOffload ? 256 : 128,
        microBatchSize: prefersAggressiveGPUOffload ? 64 : 32,
        threadCount: min(max(ProcessInfo.processInfo.activeProcessorCount - 2, 2), 4),
        batchThreadCount: prefersAggressiveGPUOffload ? 2 : 1,
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
            // 絆はThinkingを有効にする。LiteRT-LMでは推論と本文が同じ出力予算を
            // 使うため、512では本文前に止まりやすい。Gemma 4の推奨に近いsamplingで
            // 物語として自然な揺らぎを確保する。
            return GenerationPreset(maxTokens: 1_024, temperature: 0.72, topP: 0.95, topK: 40, seed: 24)
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
