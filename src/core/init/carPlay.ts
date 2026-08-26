import { AppState, Platform } from 'react-native'
import listState from '@/store/list/state'
import { playListById } from '@/core/player/player'
import {
  drainCarPlayPendingActions,
  onCarPlayAction,
  setCarPlayLibrarySnapshot,
  type CarPlayAction,
  type CarPlayLibrarySnapshot,
} from '@/utils/nativeModules/carPlay'

let initialized = false

const stringValue = (value: unknown) => typeof value == 'string' ? value : ''

const createSnapshot = (): CarPlayLibrarySnapshot => ({
  lists: listState.allList.map((list) => {
    const songs = listState.allMusicList.get(list.id) ?? []
    return {
      id: list.id,
      name: list.name,
      songs: songs.map(music => ({
        id: music.id,
        name: stringValue(music.name) || '未知歌曲',
        singer: stringValue(music.singer),
        album: stringValue(music.album),
      })),
    }
  }),
})

const syncLibrary = async() => {
  if (Platform.OS != 'ios') return
  await setCarPlayLibrarySnapshot(createSnapshot()).catch((err) => {
    console.warn('CarPlay library sync failed', err)
  })
}

const handleAction = (action: CarPlayAction) => {
  switch (action.type) {
    case 'play':
      if (!action.listId || !action.id) return
      void playListById(action.listId, action.id).catch((err) => {
        console.warn('CarPlay play request failed', err)
      })
      break
    case 'refresh':
      void syncLibrary()
      break
  }
}

export default async() => {
  if (Platform.OS != 'ios' || initialized) return
  initialized = true

  onCarPlayAction(handleAction)
  const pendingActions = await drainCarPlayPendingActions().catch(() => [])
  for (const action of pendingActions) handleAction(action)

  await syncLibrary()

  AppState.addEventListener('change', (state) => {
    if (state == 'active') void syncLibrary()
  })
}
