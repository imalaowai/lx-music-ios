declare module 'react-native/Libraries/Image/resolveAssetSource' {
  interface ResolvedAssetSource {
    uri?: string
  }

  const resolveAssetSource: (source: unknown) => ResolvedAssetSource | null | undefined
  export default resolveAssetSource
}
