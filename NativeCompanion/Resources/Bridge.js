(function () {
  'use strict';
  if (window.top !== window || !window.webkit?.messageHandlers?.lxNative) return;
  if (document.documentElement) document.documentElement.dataset.nativeApp = 'true';
  else document.addEventListener('DOMContentLoaded', () => {document.documentElement.dataset.nativeApp = 'true';}, {once: true});
  // Installed pages own their version and never register a web service worker.
  const pending = new Map(); let sequence = 0, applying = false, installed = false, authKey = '', listKey = '';
  let playback = {queue: [], index: -1, paused: true, position: 0, duration: 0};
  let renderedQueue = -1, renderedSong = '', renderedQuality = '', selection = 0;
  let room = {binding: null, state: {}, participants: [], connected: false, enabled: true, syncOnTrack: true};
  const post = (op, values = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => {pending.delete(id); reject(new Error('App 暂未回应，请重新打开页面'));}, 45000);
    pending.set(id, {resolve, reject, timer});
    window.webkit.messageHandlers.lxNative.postMessage({id, op, ...values});
  });
  const warn = error => window.showError?.(error.message || String(error));
  const send = (op, values) => post(op, values).catch(warn);
  const key = song => String(song?.songmid || song?.mid || song?.id || `${song?.name || ''}-${song?.singer || song?.artist || ''}`);
  const stubSession = {metadata: null, playbackState: 'none', setActionHandler() {}, setPositionState() {}};
  try { Object.defineProperty(navigator, 'mediaSession', {value: stubSession, configurable: true}); } catch {}
  // Block the HTML audio engine before the page restores any old playback.
  const originalPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () { return this.id === 'audio-player' || this.id === 'ios-audio-anchor' ? Promise.resolve() : originalPlay.apply(this, arguments); };
  window.QueueAudio = {install() {}, controls() {}, begin() {}, cancel() {}, noteSeek() {}, noteTrack() {}, arm() {}, ownsEnded: true, isTransitioning: () => false};
  const nativeRoom = {
    isActive: () => !!room.binding && room.enabled && room.syncOnTrack,
    isConnected: () => room.connected, getBinding: () => room.binding, debugState: () => room,
    isController: () => !!room.participantId && room.state?.controllerId === room.participantId,
    wantsPlayback: () => room.state?.paused === false,
    markUserControl() {}, prepareTrackCommand() {},
    refreshBinding: () => post('roomRefresh'), recoverConnection: () => send('roomRefresh'),
    requestPlayback: paused => send(paused === true ? 'pause' : paused === false ? 'play' : playback.paused ? 'play' : 'pause'),
    handleSystemTrackControl: direction => send(direction === 'previous' ? 'previous' : 'next'),
    sendRoomState: (reason, origin) => {if (!applying && origin === 'user' && ['queue', 'mode'].includes(reason)) syncQueue();},
    createRoom: () => membership('create'), joinRoom: () => membership('join'), leaveRoom: () => membership('leave'),
    reportTrackFailure() {}, disconnect: () => send('roomRefresh')
  };
  window.ListenRoom = nativeRoom;
  window.iOSBackgroundAudio = {usesNativePlayback: () => true, isIOS: () => true, init() {}, prepare() {}, ensureAnchorPlaying() {}, mediaUrl: value => value, play: () => post('play')};
  function audioElement() { return document.getElementById('audio-player'); }
  function receiveState(state) {
    const previous = playback; playback = {...playback, ...state}; state = playback;
    if (!installed) return;
    applying = true;
    try {
      if (Array.isArray(state.queue)) currentPlaylist = state.queue;
      currentIndex = state.index; playMode = state.mode || 'list';
      currentPlayingSong = state.song?.name ? state.song : null; window.currentPlayingSong = currentPlayingSong;
      requestedRoomSong = currentPlayingSong; roomAudioSongKey = key(currentPlayingSong);
      currentQuality = state.quality || null; playbackProgressReady = state.duration > 0;
      shouldAutoRecoverPlayback = !state.paused; currentLoadingSongId = null;
      const changedSong = key(state.song) !== renderedSong;
      if (state.song?.name && (changedSong || renderedQuality !== state.quality)) { updatePlayerInfo(state.song, state.quality); renderedQuality = state.quality; }
      if (changedSong && state.song?.name) { renderedSong = key(state.song); try {fetchLyric(state.song, state.quality); savePlayHistory(state.song, state.quality);} catch {} }
      updatePlayButton(!state.paused);
      setPlayerStatus(state.error || (state.loading ? '正在获取播放链接' : ''), !state.paused);
      const audio = audioElement();
      if (audio) {
        audio.dispatchEvent(new Event('timeupdate'));
        // Lyrics follow native playback; do not dispatch HTML play/pause recovery handlers.
        if (typeof lyricPlayer !== 'undefined' && lyricPlayer) {
          if (state.paused) lyricPlayer.pause();
          else if (state.playing && (!previous.playing || changedSong)) lyricPlayer.play(state.position * 1000);
        }
      }
      if (typeof updatePlayModeUI === 'function') updatePlayModeUI();
      if (typeof renderQueue === 'function' && (renderedQueue !== state.queueRevision || changedSong || previous.index !== state.index)) {renderQueue(); renderedQueue = state.queueRevision;}
      if (state.error) document.getElementById('lx-native-state')?.replaceChildren(document.createTextNode(state.error));
    } catch (error) { console.warn('[LX Native] UI update', error); }
    finally { applying = false; }
  }
  function receiveRoom(state) {
    room = state;
    const get = id => document.getElementById(id);
    if (get('listen-room-status')) get('listen-room-status').textContent = room.binding ? `${room.binding.roomId} · ${room.connected ? room.participants.length + ' 位成员一起听' : '连接中…'}` : '和朋友分享同一段旋律';
    if (get('listen-room-roomid')) get('listen-room-roomid').textContent = room.binding?.roomId || '—';
    if (get('listen-room-participants')) {
      const container = get('listen-room-participants'); container.replaceChildren();
      for (const member of room.participants || []) {
        const row = document.createElement('div'); row.className = 'room-member';
        const label = document.createElement('span'); label.textContent = (member.id === room.state?.controllerId ? '♛ ' : '') + (member.nickname || member.name || '成员'); row.append(label); container.append(row);
      }
    }
    window.dispatchEvent(new CustomEvent('lx-room-members-change', {detail: {participants: room.participants || [], controllerId: room.state?.controllerId || '', owner: room.owner || '', roomId: room.binding?.roomId || ''}}));
  }
  window.LXBridge = {
    reply(id, value, error) {const item = pending.get(id); if (!item) return; pending.delete(id); clearTimeout(item.timer); error ? item.reject(new Error(error)) : item.resolve(value);},
    state: receiveState, room: receiveRoom,
    chat(type, data) {window.dispatchEvent(new CustomEvent(type === 'room:chat-history' ? 'lx-room-chat-history' : 'lx-room-chat-update', {detail: {...data, roomId: room.binding?.roomId || ''}}));},
    revoked() {localStorage.removeItem('lx_user_token'); window.dispatchEvent(new CustomEvent('lx-auth-revoked'));}
  };
  function preferences() {
    try { return {quality: settings.preferredQuality || 'flac', allowFallback: settings.enableAutoDegradeQuality !== false, mode: playMode || 'list'}; }
    catch { return {quality: 'flac', allowFallback: true, mode: 'list'}; }
  }
  function syncAuth() {
    const username = localStorage.getItem('lx_sync_user') || '', token = localStorage.getItem('lx_user_token') || '';
    const value = JSON.stringify({username, token});
    if (value === authKey) return; authKey = value;
    post('auth', {username, token}).catch(warn);
  }
  const originalSet = Storage.prototype.setItem, originalRemove = Storage.prototype.removeItem, originalClear = Storage.prototype.clear;
  Storage.prototype.setItem = function (key, value) {originalSet.call(this, key, value); if (this === localStorage && ['lx_sync_user', 'lx_user_token', 'lx_settings', 'lx_play_mode'].includes(key)) queueMicrotask(() => {syncAuth(); if (installed) send('preferences', preferences());});};
  Storage.prototype.removeItem = function (key) {originalRemove.call(this, key); if (this === localStorage && ['lx_sync_user', 'lx_user_token'].includes(key)) queueMicrotask(syncAuth);};
  Storage.prototype.clear = function () {originalClear.call(this); if (this === localStorage) queueMicrotask(syncAuth);};
  async function importDevice(song) {
    const cached = await post('importLookup', {key: song.deviceKey});
    if (cached.url) return {...song, url: cached.url, isLocal: true, deviceKey: undefined};
    const blob = await window.DeviceLibrary.blobFor(song, false);
    if (!blob || blob.size > 500 * 1024 * 1024) throw new Error('设备文件无法读取，或超过 500 MB');
    const opened = await post('importBegin', {key: song.deviceKey, name: song.filename || song.name + '.mp3'});
    try {
      for (let at = 0; at < blob.size; at += 48 * 1024) {
        const bytes = new Uint8Array(await blob.slice(at, at + 48 * 1024).arrayBuffer());
        let content = ''; for (const byte of bytes) content += String.fromCharCode(byte);
        await post('importChunk', {ticket: opened.ticket, data: btoa(content)});
      }
      const imported = await post('importEnd', {ticket: opened.ticket});
      return {...song, url: imported.url, isLocal: true, deviceKey: undefined};
    } catch (error) {send('importCancel', {ticket: opened.ticket}); throw error;}
  }
  async function select(song, index, quality, noPlay) {
    if (noPlay) return;
    const request = ++selection;
    syncAuth();
    let queue = window.__LX_PLAYER_GETTERS__?.getCurrentPlaylist?.()?.slice() || [song];
    let at = Number.isInteger(index) && key(queue[index]) === key(song) ? index : queue.findIndex(item => key(item) === key(song));
    if (at < 0) {queue = [song]; at = 0;}
    for (let i = 0; i < queue.length; i++) {
      if (request !== selection) return;
      if (queue[i].deviceKey) {window.setPlayerStatus?.(`正在准备设备音乐 ${i + 1}/${queue.length}`, false); queue[i] = await importDevice(queue[i]);}
    }
    if (request !== selection) return;
    await post('select', {queue, index: at, ...preferences(), ...(quality ? {quality} : {})});
    window.MobileShell?.openOnPlay?.();
  }
  function syncQueue() {if (applying) return; const api = window.__LX_PLAYER_GETTERS__; if (api) send('queue', {queue: api.getCurrentPlaylist(), index: api.getCurrentIndex(), ...preferences()});}
  function membership(operation) {
    const prefix = operation === 'create' ? 'create' : 'join';
    return post('roomMembership', {operation, roomId: document.getElementById(`listen-room-${prefix}-id`)?.value?.trim() || '', password: document.getElementById(`listen-room-${prefix}-password`)?.value || ''}).catch(warn);
  }
  function modal(show) {const node = document.getElementById('listen-room-modal'); node?.classList.toggle('hidden', !show); node?.classList.toggle('flex', show);}
  function install() {
    if (installed || !window.__LX_PLAYER_GETTERS__) return;
    installed = true;
    const audio = audioElement();
    if (audio) {
      let deviceVolume = Number(audio.volume) || 1, deviceMuted = !!audio.muted;
      const properties = {volume: {get: () => deviceVolume, set: value => {deviceVolume = Math.max(0, Math.min(1, Number(value))); if (!applying) send('volume', {volume: deviceVolume, muted: deviceMuted});}}, muted: {get: () => deviceMuted, set: value => {deviceMuted = !!value; if (!applying) send('volume', {volume: deviceVolume, muted: deviceMuted});}}, currentTime: {get: () => playback.position || 0, set: value => {if (!applying) send('seek', {time: Number(value)});}}, duration: {get: () => playback.duration || NaN}, paused: {get: () => playback.paused !== false}, ended: {get: () => false}, readyState: {get: () => playback.duration > 0 ? 4 : 0}, seeking: {get: () => false}};
      for (const [name, descriptor] of Object.entries(properties)) Object.defineProperty(audio, name, {...descriptor, configurable: true});
      Object.defineProperty(audio, 'src', {get: () => playback.song?.name ? 'lx-native://current' : '', set() {}, configurable: true});
      audio.load = () => {}; audio.play = () => post('play'); audio.pause = () => {if (!applying) send('pause');};
    }
    window.playSong = (...args) => select(...args).catch(warn);
    window.loadSong = window.playSong;
    window.playNext = () => post('next'); window.playPrev = () => post('previous');
    window.togglePlay = paused => post(typeof paused === 'boolean' ? paused ? 'pause' : 'play' : playback.paused ? 'play' : 'pause');
    if (window.ListenRoom !== nativeRoom) {try {window.ListenRoom?.disconnect?.();} catch {}}
    window.ListenRoom = nativeRoom;
    window.prefetchNextSong = async () => {};
    window.handleUnexpectedPlaybackPause = () => false;
    window.soundEffects && (window.soundEffects.init = () => {});
    document.getElementById('ios-audio-mode')?.remove();
    const settingsView = document.getElementById('view-settings');
    if (settingsView) {
      const card = document.createElement('section'); card.className = 'media-settings-card lx-native-settings';
      const title = document.createElement('h3'); title.textContent = 'LX 音乐'; card.append(title);
      const label = document.createElement('p'); label.id = 'lx-native-state'; label.textContent = '内置界面 · 原生播放 · CarPlay'; card.append(label);
      const address = document.createElement('p'); address.className = 'lx-server-address'; card.append(address);
      const button = document.createElement('button'); button.type = 'button'; button.className = 'apple-secondary'; button.textContent = '更换音乐服务器'; button.onclick = () => send('editServer'); card.append(button);
      const version = document.createElement('p'); version.className = 'lx-app-version'; card.append(version); settingsView.prepend(card);
      post('appInfo').then(info => {address.textContent = info.server || ''; version.textContent = 'App ' + info.version + ' · 内置界面 ' + (window.CONFIG?.version || '');}).catch(warn);
    }
    document.getElementById('listen-room-btn')?.addEventListener('click', () => modal(true));
    document.getElementById('listen-room-close')?.addEventListener('click', () => modal(false));
    document.getElementById('listen-room-modal')?.addEventListener('click', event => {if (event.target.id === 'listen-room-modal') modal(false);});
    for (const operation of ['create', 'join', 'leave']) document.getElementById(`listen-room-${operation}-action`)?.addEventListener('click', () => membership(operation));
    document.getElementById('listen-room-copy-action')?.addEventListener('click', () => {if (room.binding?.roomId) navigator.clipboard?.writeText(room.binding.roomId).catch(warn);});
    document.getElementById('listen-room-refresh-action')?.addEventListener('click', () => send('roomRefresh'));
    const api = window.__LX_PLAYER_GETTERS__, originalEnqueue = api.enqueue;
    api.enqueue = function () {const result = originalEnqueue.apply(this, arguments); syncQueue(); return result;};
    for (const name of ['removeFromQueue', 'clearQueue']) {
      const original = window[name];
      if (typeof original === 'function') window[name] = async function () {const result = await original.apply(this, arguments); syncQueue(); return result;};
    }
    const originalMode = window.updatePlayModeUI;
    window.updatePlayModeUI = function () {const result = originalMode?.apply(this, arguments); if (!applying) send('preferences', preferences()); return result;};
    syncAuth(); send('preferences', preferences()); send('ready');
    receiveState(playback); receiveRoom(room);
    setTimeout(() => send('uiReady', {bundled: window.__LX_BUNDLED_UI__ === true, mobile: !!window.MobileShell, themes: !!window.DesktopLayout}), 0);
    // Foreground UI state only; audio and room networking run natively.
    setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      syncAuth();
      const data = window.__LX_LIBRARY_GETTERS__?.getData?.();
      if (!data) return;
      const lists = [{id: 'love', name: '我的收藏', list: data.loveList || []}, {id: 'default', name: '默认列表', list: data.defaultList || []}, ...(data.userList || [])];
      const serialized = JSON.stringify(lists);
      if (serialized !== listKey) {listKey = serialized; send('library', {lists});}
    }, 2500);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install); else install();
})();
