import { NativeEventEmitter, NativeModules, Platform } from 'react-native'

export interface CarPlayMusicItem {
  id: string
  name: string
  singer: string
  album: string
}

export interface CarPlayListItem {
  id: string
  name: string
  kind: 'default' | 'love' | 'user'
  musics: CarPlayMusicItem[]
}

export interface CarPlayRecentItem extends CarPlayMusicItem {
  listId: string
}

export interface CarPlayLibrarySnapshot {
  version: 2
  updatedAt: number
  lists: CarPlayListItem[]
  recent: CarPlayRecentItem[]
}

export type CarPlayAction =
  | { type: 'play', listId: string, musicId: string }
  | { type: 'refresh-library' }

interface NativeCarPlayModule {
  updateLibrary: (snapshot: CarPlayLibrarySnapshot) => Promise<void>
  addListener: (eventName: string) => void
  removeListeners: (count: number) => void
}

const nativeModule = NativeModules.CarPlayModule as NativeCarPlayModule | undefined

export const isCarPlayBridgeAvailable = Platform.OS == 'ios' && nativeModule != null && typeof nativeModule.updateLibrary == 'function'

export const updateCarPlayLibrary = async(snapshot: CarPlayLibrarySnapshot) => {
  if (!isCarPlayBridgeAvailable || !nativeModule) return
  await nativeModule.updateLibrary(snapshot)
}

export const onCarPlayAction = (listener: (action: CarPlayAction) => void) => {
  if (!isCarPlayBridgeAvailable || !nativeModule) return () => {}
  const emitter = new NativeEventEmitter(nativeModule)
  const subscription = emitter.addListener('carplay-action', listener)
  return () => {
    subscription.remove()
  }
}
