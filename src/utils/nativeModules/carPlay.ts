import { NativeEventEmitter, NativeModules, Platform } from 'react-native'

export type CarPlayMusicItem = {
  id: string
  name: string
  singer: string
  album: string
}

export type CarPlayListItem = {
  id: string
  name: string
  kind: 'default' | 'love' | 'user'
  musics: CarPlayMusicItem[]
}

export type CarPlayLibrarySnapshot = {
  version: 2
  updatedAt: number
  lists: CarPlayListItem[]
  recent: Array<CarPlayMusicItem & { listId: string }>
}

export type CarPlayAction =
  | { type: 'play', listId: string, musicId: string }
  | { type: 'refresh-library' }

interface NativeCarPlayModule {
  updateLibrary: (snapshot: CarPlayLibrarySnapshot) => Promise<void>
  addListener?: (eventName: string) => void
  removeListeners?: (count: number) => void
}

const nativeModule = NativeModules.CarPlayModule as NativeCarPlayModule | undefined

export const isCarPlayBridgeAvailable = Platform.OS == 'ios' && nativeModule != null && typeof nativeModule.updateLibrary == 'function'

export const updateCarPlayLibrary = async(snapshot: CarPlayLibrarySnapshot) => {
  if (!isCarPlayBridgeAvailable) return
  await nativeModule!.updateLibrary(snapshot)
}

export const onCarPlayAction = (listener: (action: CarPlayAction) => void) => {
  if (!isCarPlayBridgeAvailable || !nativeModule) return () => {}
  const emitter = new NativeEventEmitter(nativeModule as any)
  const subscription = emitter.addListener('carplay-action', listener)
  return () => subscription.remove()
}
