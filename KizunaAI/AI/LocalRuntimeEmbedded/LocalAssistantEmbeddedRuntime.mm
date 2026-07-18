#import "LocalAssistantEmbeddedRuntime.h"

#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include "llama.h"
#include <algorithm>
#include <string>
#include <vector>
#endif

@implementation VIUKEmbeddedRuntimeResult

- (instancetype)initWithSuccess:(BOOL)success
                           text:(nullable NSString *)text
                   errorMessage:(nullable NSString *)errorMessage {
    self = [super init];
    if (self) {
        _success = success;
        _text = [text copy];
        _errorMessage = [errorMessage copy];
    }
    return self;
}

@end

#if TARGET_OS_OSX
namespace {

static std::string VIUKToStdString(NSString *value) {
    if (value == nil) {
        return {};
    }
    return std::string(value.UTF8String ?: "");
}

static NSString * VIUKTrimmed(NSString *value) {
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString * VIUKStripSpecialTokenFragments(NSString *value) {
    NSString *cleaned = value ?: @"";
    NSArray<NSString *> *patterns = @[
        @"<\\|[^\\n]*?(?:\\|>|$)",
        @"(?m)^\\s*\\|>\\s*$"
    ];

    for (NSString *pattern in patterns) {
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
        if (regex == nil || error != nil) {
            continue;
        }
        cleaned = [regex stringByReplacingMatchesInString:cleaned
                                                  options:0
                                                    range:NSMakeRange(0, cleaned.length)
                                             withTemplate:@""];
    }

    return VIUKTrimmed(cleaned);
}

static NSString * VIUKCleanOutput(NSString *value) {
    NSString *cleaned = value ?: @"";
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"<end_of_turn>" withString:@""];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"<start_of_turn>model" withString:@""];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"<start_of_turn>assistant" withString:@""];
    cleaned = [cleaned stringByReplacingOccurrencesOfString:@"<start_of_turn>user" withString:@""];
    cleaned = VIUKStripSpecialTokenFragments(cleaned);
    return VIUKTrimmed(cleaned);
}

static std::vector<llama_token> VIUKTokenize(const llama_vocab * vocab, NSString *text, NSString **errorMessage) {
    const std::string utf8 = VIUKToStdString(text);
    if (utf8.empty()) {
        if (errorMessage) {
            *errorMessage = @"プロンプトが空です。";
        }
        return {};
    }

    int32_t capacity = std::max<int32_t>(static_cast<int32_t>(utf8.size()) + 32, 256);
    std::vector<llama_token> tokens(static_cast<size_t>(capacity));

    int32_t tokenCount = llama_tokenize(vocab, utf8.c_str(), static_cast<int32_t>(utf8.size()), tokens.data(), capacity, true, true);
    if (tokenCount < 0) {
        capacity = -tokenCount;
        tokens.resize(static_cast<size_t>(capacity));
        tokenCount = llama_tokenize(vocab, utf8.c_str(), static_cast<int32_t>(utf8.size()), tokens.data(), capacity, true, true);
    }

    if (tokenCount <= 0) {
        if (errorMessage) {
            *errorMessage = @"プロンプトのトークナイズに失敗しました。";
        }
        return {};
    }

    tokens.resize(static_cast<size_t>(tokenCount));
    return tokens;
}

static std::string VIUKPieceForToken(const llama_vocab * vocab, llama_token token) {
    std::vector<char> buffer(256);
    int32_t written = llama_token_to_piece(vocab, token, buffer.data(), static_cast<int32_t>(buffer.size()), 0, true);
    if (written < 0) {
        buffer.resize(static_cast<size_t>(-written));
        written = llama_token_to_piece(vocab, token, buffer.data(), static_cast<int32_t>(buffer.size()), 0, true);
    }
    if (written <= 0) {
        return {};
    }
    return std::string(buffer.data(), static_cast<size_t>(written));
}

static void VIUKClearBatch(struct llama_batch &batch) {
    batch.n_tokens = 0;
}

static void VIUKAddTokenToBatch(struct llama_batch &batch, llama_token token, int32_t position, bool logits) {
    batch.token[batch.n_tokens] = token;
    batch.pos[batch.n_tokens] = position;
    batch.n_seq_id[batch.n_tokens] = 1;
    batch.seq_id[batch.n_tokens][0] = 0;
    batch.logits[batch.n_tokens] = logits;
    batch.n_tokens += 1;
}

}
#endif

@interface VIUKEmbeddedRuntime () {
#if TARGET_OS_OSX
    struct llama_model *_loadedModel;
    NSString *_loadedModelPath;
    NSLock *_lock;
    BOOL _backendFreed;
#endif
}
@end

@implementation VIUKEmbeddedRuntime

+ (instancetype)shared {
    static VIUKEmbeddedRuntime *sharedRuntime = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedRuntime = [[VIUKEmbeddedRuntime alloc] init];
    });
    return sharedRuntime;
}

- (instancetype)init {
    self = [super init];
    if (self) {
#if TARGET_OS_OSX
        _lock = [[NSLock alloc] init];
        static dispatch_once_t backendOnce;
        dispatch_once(&backendOnce, ^{
            llama_backend_init();
        });
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillTerminate:)
                                                     name:NSApplicationWillTerminateNotification
                                                   object:nil];
#endif
    }
    return self;
}

- (void)dealloc {
#if TARGET_OS_OSX
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self clearCachedModel];
#endif
}

- (void)clearCachedModel {
#if TARGET_OS_OSX
    [_lock lock];
    if (_loadedModel != nullptr) {
        llama_model_free(_loadedModel);
        _loadedModel = nullptr;
    }
    _loadedModelPath = nil;
    [_lock unlock];
#endif
}

- (void)applicationWillTerminate:(NSNotification *)notification {
#if TARGET_OS_OSX
    (void)notification;
    [self clearCachedModel];
    [_lock lock];
    if (!_backendFreed) {
        llama_backend_free();
        _backendFreed = YES;
    }
    [_lock unlock];
#endif
}

#if TARGET_OS_OSX
- (struct llama_model *)loadModelAtPath:(NSString *)modelPath error:(NSString * __autoreleasing *)errorMessage {
    if (_loadedModel != nullptr && [_loadedModelPath isEqualToString:modelPath]) {
        return _loadedModel;
    }

    if (_loadedModel != nullptr) {
        llama_model_free(_loadedModel);
        _loadedModel = nullptr;
        _loadedModelPath = nil;
    }

    llama_model_params modelParams = llama_model_default_params();
    modelParams.use_mmap = true;
    modelParams.use_mlock = false;
    modelParams.check_tensors = false;
    // Prefer the conservative CPU path first. The previous GPU/Metal-first
    // configuration could survive model load and then abort inside
    // llama_decode() on some Macs.
    modelParams.n_gpu_layers = 0;

    struct llama_model *model = llama_model_load_from_file(modelPath.fileSystemRepresentation, modelParams);

    if (model == nullptr) {
        if (errorMessage) {
            *errorMessage = @"モデルファイルの読み込みに失敗しました。";
        }
        return nullptr;
    }

    _loadedModel = model;
    _loadedModelPath = [modelPath copy];
    return _loadedModel;
}

- (VIUKEmbeddedRuntimeResult *)generateLockedWithPrompt:(NSString *)prompt
                                             modelPath:(NSString *)modelPath
                                             maxTokens:(NSInteger)maxTokens
                                           temperature:(float)temperature
                                                  topP:(float)topP
                                                  topK:(NSInteger)topK
                                                  seed:(uint32_t)seed {
    NSString *errorMessage = nil;
    struct llama_model *model = [self loadModelAtPath:modelPath error:&errorMessage];
    if (model == nullptr) {
        return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:errorMessage];
    }

    const struct llama_vocab *vocab = llama_model_get_vocab(model);
    std::vector<llama_token> promptTokens = VIUKTokenize(vocab, prompt, &errorMessage);
    if (promptTokens.empty()) {
        return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:errorMessage];
    }

    llama_context_params contextParams = llama_context_default_params();
    const int32_t modelCtx = std::max<int32_t>(llama_model_n_ctx_train(model), 1024);
    const int32_t reservedOutputTokens = std::max<int32_t>(static_cast<int32_t>(maxTokens) + 16, 160);
    const int32_t maxPromptTokens = std::max<int32_t>(128, modelCtx - reservedOutputTokens);
    if (static_cast<int32_t>(promptTokens.size()) > maxPromptTokens) {
        promptTokens.erase(
            promptTokens.begin(),
            promptTokens.end() - maxPromptTokens
        );
    }

    const int32_t promptCount = static_cast<int32_t>(promptTokens.size());
    const int32_t desiredCtx = std::min<int32_t>(modelCtx, std::max<int32_t>(1024, promptCount + static_cast<int32_t>(maxTokens) + 64));
    const int32_t threadCount = std::max<int32_t>(2, static_cast<int32_t>(NSProcessInfo.processInfo.activeProcessorCount) - 1);

    const int32_t safeBatchSize = std::max<int32_t>(1, std::min<int32_t>(std::min<int32_t>(promptCount, desiredCtx), 64));

    contextParams.n_ctx = static_cast<uint32_t>(desiredCtx);
    contextParams.n_batch = static_cast<uint32_t>(safeBatchSize);
    contextParams.n_ubatch = static_cast<uint32_t>(std::min<int32_t>(safeBatchSize, 32));
    contextParams.n_seq_max = 1;
    contextParams.n_threads = std::max<int32_t>(1, std::min<int32_t>(threadCount, 6));
    contextParams.n_threads_batch = 1;
    // Prefer the more conservative CPU path first. The previous configuration
    // could abort inside llama_decode on some Macs before we could recover.
    contextParams.offload_kqv = false;
    contextParams.no_perf = true;

    struct llama_context *ctx = llama_init_from_model(model, contextParams);
    if (ctx == nullptr) {
        return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:@"ローカル実行コンテキストの初期化に失敗しました。"];
    }

    const int32_t decodeThreadCount = contextParams.n_threads;
    const int32_t batchThreadCount = contextParams.n_threads_batch;
    llama_set_n_threads(ctx, decodeThreadCount, batchThreadCount);

    llama_batch batch = llama_batch_init(safeBatchSize, 0, 1);

    const int32_t promptChunkSize = std::max<int32_t>(1, std::min<int32_t>(safeBatchSize, 32));
    for (int32_t offset = 0; offset < promptCount; offset += promptChunkSize) {
        const int32_t count = std::min<int32_t>(promptChunkSize, promptCount - offset);
        VIUKClearBatch(batch);
        for (int32_t index = 0; index < count; ++index) {
            const bool wantsLogits = (index == count - 1);
            VIUKAddTokenToBatch(batch, promptTokens[static_cast<size_t>(offset + index)], offset + index, wantsLogits);
        }
        if (llama_decode(ctx, batch) != 0) {
            llama_batch_free(batch);
            llama_free(ctx);
            return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:@"初回プロンプトの処理に失敗しました。"];
        }
    }

    llama_sampler_chain_params samplerParams = llama_sampler_chain_default_params();
    struct llama_sampler *sampler = llama_sampler_chain_init(samplerParams);
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(static_cast<int32_t>(topK)));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed == 0 ? LLAMA_DEFAULT_SEED : seed));

    std::string generated;
    generated.reserve(static_cast<size_t>(std::max<NSInteger>(maxTokens, 32)) * 8);

    int32_t nextPosition = promptCount;
    for (NSInteger index = 0; index < maxTokens; index += 1) {
        const llama_token token = llama_sampler_sample(sampler, ctx, -1);
        if (token == LLAMA_TOKEN_NULL || llama_vocab_is_eog(vocab, token) || token == llama_vocab_eos(vocab)) {
            break;
        }

        llama_sampler_accept(sampler, token);
        generated += VIUKPieceForToken(vocab, token);

        VIUKClearBatch(batch);
        VIUKAddTokenToBatch(batch, token, nextPosition, true);
        nextPosition += 1;
        if (llama_decode(ctx, batch) != 0) {
            llama_batch_free(batch);
            llama_sampler_free(sampler);
            llama_free(ctx);
            return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:@"ローカル生成の途中で失敗しました。"];
        }
    }

    llama_batch_free(batch);
    llama_sampler_free(sampler);
    llama_free(ctx);

    NSString *output = VIUKCleanOutput([NSString stringWithUTF8String:generated.c_str()]);
    if (output.length == 0) {
        return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:@"ローカル生成の結果が空でした。"];
    }

    return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:YES text:output errorMessage:nil];
}
#endif

- (VIUKEmbeddedRuntimeResult *)performSelfCheckWithModelPath:(NSString *)modelPath
                                                   maxTokens:(NSInteger)maxTokens {
#if TARGET_OS_OSX
    [_lock lock];
    VIUKEmbeddedRuntimeResult *result = [self generateLockedWithPrompt:@"<start_of_turn>user\nこんにちは\n<end_of_turn>\n<start_of_turn>model\n"
                                                             modelPath:modelPath
                                                             maxTokens:MAX(maxTokens, 12)
                                                           temperature:0.2f
                                                                  topP:0.9f
                                                                  topK:32
                                                                  seed:1];
    [_lock unlock];
    return result;
#else
    return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:@"このプラットフォームでは埋め込み runtime を使えません。"];
#endif
}

- (VIUKEmbeddedRuntimeResult *)generateWithPrompt:(NSString *)prompt
                                        modelPath:(NSString *)modelPath
                                        maxTokens:(NSInteger)maxTokens
                                      temperature:(float)temperature
                                             topP:(float)topP
                                             topK:(NSInteger)topK
                                             seed:(uint32_t)seed {
#if TARGET_OS_OSX
    [_lock lock];
    VIUKEmbeddedRuntimeResult *result = [self generateLockedWithPrompt:prompt
                                                             modelPath:modelPath
                                                             maxTokens:MAX(maxTokens, 32)
                                                           temperature:temperature
                                                                  topP:topP
                                                                  topK:topK
                                                                  seed:seed];
    [_lock unlock];
    return result;
#else
    return [[VIUKEmbeddedRuntimeResult alloc] initWithSuccess:NO text:nil errorMessage:@"このプラットフォームでは埋め込み runtime を使えません。"];
#endif
}

@end
