#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LXSharedIRConvolutionBridge : NSObject

- (instancetype)initWithIRChannelData:(NSArray<NSData *> *)irChannelData
                     inputChannels:(NSUInteger)inputChannels
                    outputChannels:(NSUInteger)outputChannels
                         blockSize:(NSUInteger)blockSize
                           dryGain:(float)dryGain
                           wetGain:(float)wetGain NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (BOOL)isReady;
- (void)updateDryGain:(float)dryGain wetGain:(float)wetGain;
- (void)processStereoChannel0:(float * _Nonnull)channel0
                     channel1:(float * _Nullable)channel1
                   frameCount:(NSUInteger)frameCount
               activeChannels:(NSUInteger)activeChannels;

@end

NS_ASSUME_NONNULL_END
