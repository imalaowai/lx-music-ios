#import "LXSharedIRConvolutionBridge.h"
#include "LXSharedIRConvolutionKernel.hpp"

@implementation LXSharedIRConvolutionBridge {
  std::unique_ptr<LXSharedDSP::IRConvolutionKernel> _kernel;
}

- (instancetype)initWithIRChannelData:(NSArray<NSData *> *)irChannelData
                     inputChannels:(NSUInteger)inputChannels
                    outputChannels:(NSUInteger)outputChannels
                         blockSize:(NSUInteger)blockSize
                           dryGain:(float)dryGain
                           wetGain:(float)wetGain {
  self = [super init];
  if (self == nil) return nil;

  std::vector<std::vector<float>> channels;
  channels.reserve(irChannelData.count);
  for (NSData *channelData in irChannelData) {
    NSUInteger sampleCount = channelData.length / sizeof(float);
    const float *samples = (const float *)channelData.bytes;
    if (samples == nullptr || sampleCount == 0) {
      channels.emplace_back();
      continue;
    }
    channels.emplace_back(samples, samples + sampleCount);
  }

  _kernel = std::make_unique<LXSharedDSP::IRConvolutionKernel>(channels, inputChannels, outputChannels, dryGain, wetGain, blockSize);
  return self;
}

- (BOOL)isReady {
  return _kernel != nullptr && _kernel->isReady();
}

- (void)updateDryGain:(float)dryGain wetGain:(float)wetGain {
  if (_kernel == nullptr) return;
  _kernel->updateGains(dryGain, wetGain);
}

- (void)processStereoChannel0:(float * _Nonnull)channel0
                     channel1:(float * _Nullable)channel1
                   frameCount:(NSUInteger)frameCount
               activeChannels:(NSUInteger)activeChannels {
  if (_kernel == nullptr || channel0 == nullptr || activeChannels == 0) return;
  float *channels[2] = { channel0, channel1 };
  _kernel->processPCMChannels(channels, frameCount, activeChannels);
}

@end
