import resolveAssetSource from 'react-native/Libraries/Image/resolveAssetSource'

const convolutionAssetModules = {
  'filter-telephone.wav': require('@/resources/medias/filters/filter-telephone.wav'),
  's2_r4_bd.wav': require('@/resources/medias/filters/s2_r4_bd.wav'),
  'bright-hall.wav': require('@/resources/medias/filters/bright-hall.wav'),
  'cinema-diningroom.wav': require('@/resources/medias/filters/cinema-diningroom.wav'),
  'dining-living-true-stereo.wav': require('@/resources/medias/filters/dining-living-true-stereo.wav'),
  'living-bedroom-leveled.wav': require('@/resources/medias/filters/living-bedroom-leveled.wav'),
  'spreader50-65ms.wav': require('@/resources/medias/filters/spreader50-65ms.wav'),
  's3_r1_bd.wav': require('@/resources/medias/filters/s3_r1_bd.wav'),
  'matrix-reverb1.wav': require('@/resources/medias/filters/matrix-reverb1.wav'),
  'matrix-reverb2.wav': require('@/resources/medias/filters/matrix-reverb2.wav'),
  'cardiod-35-10-spread.wav': require('@/resources/medias/filters/cardiod-35-10-spread.wav'),
  'tim-omni-35-10-magnetic.wav': require('@/resources/medias/filters/tim-omni-35-10-magnetic.wav'),
  'feedback-spring.wav': require('@/resources/medias/filters/feedback-spring.wav'),
} as const

const convolutionAssetUriMap = Object.fromEntries(
  Object.entries(convolutionAssetModules).map(([name, asset]) => [name, resolveAssetSource(asset)?.uri ?? '']),
) as Record<keyof typeof convolutionAssetModules, string>

export const getConvolutionAssetUri = (fileName: string) => {
  return convolutionAssetUriMap[fileName as keyof typeof convolutionAssetUriMap] ?? ''
}
