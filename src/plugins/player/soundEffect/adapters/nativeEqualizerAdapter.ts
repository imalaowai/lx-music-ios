import { isSoundEffectSupported, updateNativeSoundEffectConfig } from '@/utils/nativeModules/soundEffect'
import type { SoundEffectAdapter } from '../types'

export const nativeEqualizerAdapter: SoundEffectAdapter = {
  id: 'native_ios_sound_effect',
  capabilities: {
    equalizer: true,
    convolution: true,
    panner: true,
    pitchShifter: true,
    presets: true,
    realTimePreview: true,
    playbackPathCoverage: {
      nativeFlac: 'supported',
      trackPlayer: 'supported',
    },
  },
  isSupported() {
    return isSoundEffectSupported
  },
  async apply(config) {
    await updateNativeSoundEffectConfig(config)
  },
}
