import { Platform } from 'react-native'
import { LIST_IDS } from '@/config/constant'
import listState from '@/store/list/state'
import playerState from '@/store/player/state'
import { getListMusics } from '@/core/list'
import { playListById } from '@/core/player/player'
import {
  isCarPlayBridgeAvailable,
  onCarPlayAction,
  updateCarPlayLibrary,
  type CarPlayAction,
  type CarPlayLibrarySnapshot,
  type CarPlayMusicItem,
} from '@/utils/nativeModules/carPlay'

const MAX_TOTAL_TRACKS = 25000
const MAX_TRACKS_PER_LIST = 5000
const MAX_RECENT_TRACKS = 100

let refreshTimer: ReturnType<typeof setTimeout> | null = null
let refreshPromise: Promise<void> = Promise.resolve()
let initialized = false

const normalizeMusic = (musicInfo: LX.Music.MusicInfo): CarPlayMusicItem => ({
  id: String(musicInfo.id),
  name: musicInfo.name || '未知歌曲',
  singer: musicInfo.singer || '',
  album: musicInfo.meta?.albumName || '',
})

const readListMusics = async(listId: string) => {
  try {
    return await getListMusics(listId)
  } catch (err) {
    console.log('CarPlay: failed to load list', listId, err)
    return listState.allMusicList.get(listId) ?? []
  }
}

const createSnapshot = async(): Promise<CarPlayLibrarySnapshot> => {
  const lists: CarPlayLibrarySnapshot['lists'] = []
  let remaining = MAX_TOTAL_TRACKS

  for (const list of listState.allList) {
    const musics = await readListMusics(list.id)
    const take = Math.max(0, Math.min(musics.length, MAX_TRACKS_PER_LIST, remaining))
    remaining -= take

    lists.push({
      id: list.id,
      name: list.name || '未命名歌单',
      kind: list.id == LIST_IDS.LOVE ? 'love' : list.id == LIST_IDS.DEFAULT ? 'default' : 'user',
      musics: musics.slice(0, take).map(normalizeMusic),
    })
  }

  const recent: CarPlayLibrarySnapshot['recent'] = []
  const recentKeys = new Set<string>()
  for (let index = playerState.playedList.length - 1; index >= 0 && recent.length < MAX_RECENT_TRACKS; index--) {
    const item = playerState.playedList[index]
    if (!item?.musicInfo || !item.listId) continue
    const key = `${item.listId}:${item.musicInfo.id}`
    if (recentKeys.has(key)) continue
    recentKeys.add(key)
    const musicInfo = 'progress' in item.musicInfo ? item.musicInfo.metadata.musicInfo : item.musicInfo
    recent.push({ ...normalizeMusic(musicInfo), listId: item.listId })
  }

  return {
    version: 2,
    updatedAt: Date.now(),
    lists,
    recent,
  }
}

const refreshLibrary = async() => {
  if (!isCarPlayBridgeAvailable) return
  const snapshot = await createSnapshot()
  await updateCarPlayLibrary(snapshot)
}

const queueRefresh = (delay = 500) => {
  if (!isCarPlayBridgeAvailable) return
  if (refreshTimer) clearTimeout(refreshTimer)
  refreshTimer = setTimeout(() => {
    refreshTimer = null
    const run = async() => refreshLibrary().catch(err => console.log('CarPlay: refresh failed', err))
    refreshPromise = refreshPromise.then(run, run)
  }, delay)
}

const handleAction = async(action: CarPlayAction) => {
  if (action.type == 'refresh-library') {
    queueRefresh(50)
    return
  }

  if (action.type == 'play') {
    if (!action.listId || !action.musicId) return
    // Ensure the selected list is resident in the synchronous player list cache.
    // CarPlay may launch the app from a cold state before the phone UI ever opened this list.
    await readListMusics(action.listId)
    await playListById(action.listId, action.musicId)
  }
}

export default async() => {
  if (Platform.OS != 'ios' || !isCarPlayBridgeAvailable || initialized) return
  initialized = true

  onCarPlayAction(action => {
    void handleAction(action).catch(err => console.log('CarPlay: action failed', action, err))
  })

  // These events cover list metadata changes, list content changes, and playback-history changes.
  global.state_event.on('mylistUpdated', () => queueRefresh())
  global.app_event.on('myListMusicUpdate', () => queueRefresh())
  global.state_event.on('playPlayedListChanged', () => queueRefresh(800))

  // Publish once after normal app data initialization. The native CarPlay scene keeps the
  // last successful snapshot on disk, so future cold CarPlay launches never wait for RN.
  await refreshLibrary().catch(err => console.log('CarPlay: initial snapshot failed', err))
}
