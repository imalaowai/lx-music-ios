import { NativeEventEmitter, NativeModules, Platform } from 'react-native'

const { CarPlayModule } = NativeModules

export interface CarPlaySongSnapshot {
  id: string
  name: string
  singer: string
  album: string
}

export interface CarPlayListSnapshot {
  id: string
  name: string
  songs: CarPlaySongSnapshot[]
}

export interface CarPlayLibrarySnapshot {
  lists: CarPlayListSnapshot[]
}

export type CarPlayAction =
  | { type: 'play', listId: string, id: string }
  | { type: 'refresh' }

interface CarPlayEventModule {
  addListener: (eventName: string) => void
  removeListeners: (count: number) => void
}

const createEmitter = () => CarPlayModule &&
  typeof CarPlayModule.addListener == 'function' &&
  typeof CarPlayModule.removeListeners == 'function'
  ? new NativeEventEmitter(CarPlayModule as CarPlayEventModule)
  : null

export const setCarPlayLibrarySnapshot = async(snapshot: CarPlayLibrarySnapshot) => {
  if (Platform.OS != 'ios' || typeof CarPlayModule?.setLibrarySnapshot != 'function') return false
  return CarPlayModule.setLibrarySnapshot(snapshot) as Promise<boolean>
}

export const drainCarPlayPendingActions = async(): Promise<CarPlayAction[]> => {
  if (Platform.OS != 'ios' || typeof CarPlayModule?.drainPendingActions != 'function') return []
  return CarPlayModule.drainPendingActions() as Promise<CarPlayAction[]>
}

export const isCarPlayConnected = async(): Promise<boolean> => {
  if (Platform.OS != 'ios' || typeof CarPlayModule?.isConnected != 'function') return false
  return CarPlayModule.isConnected() as Promise<boolean>
}

export const onCarPlayAction = (handler: (event: CarPlayAction) => void): (() => void) => {
  if (Platform.OS != 'ios') return () => {}
  const emitter = createEmitter()
  if (!emitter) return () => {}
  const subscription = emitter.addListener('carplay-action', event => {
    handler(event as CarPlayAction)
  })
  return () => subscription.remove()
}
