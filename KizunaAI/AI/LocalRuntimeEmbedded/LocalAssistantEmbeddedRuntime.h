#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VIUKEmbeddedRuntimeResult : NSObject

@property (nonatomic, readonly) BOOL success;
@property (nonatomic, copy, readonly, nullable) NSString *text;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;

- (instancetype)initWithSuccess:(BOOL)success
                           text:(nullable NSString *)text
                   errorMessage:(nullable NSString *)errorMessage;

@end

@interface VIUKEmbeddedRuntime : NSObject

+ (instancetype)shared;

- (VIUKEmbeddedRuntimeResult *)performSelfCheckWithModelPath:(NSString *)modelPath
                                                   maxTokens:(NSInteger)maxTokens;

- (VIUKEmbeddedRuntimeResult *)generateWithPrompt:(NSString *)prompt
                                        modelPath:(NSString *)modelPath
                                        maxTokens:(NSInteger)maxTokens
                                      temperature:(float)temperature
                                             topP:(float)topP
                                             topK:(NSInteger)topK
                                             seed:(uint32_t)seed;

- (void)clearCachedModel;

@end

NS_ASSUME_NONNULL_END
