(function () {
  'use strict';
  if (window.top !== window || !window.webkit?.messageHandlers?.lxNative) return;
  if (document.documentElement) document.documentElement.dataset.nativeApp = 'true';
  else document.addEventListener('DOMContentLoaded', () => {document.documentElement.dataset.nativeApp = 'true';}, {once: true});
  // Installed pages own their version and never register a web service worker.
  const pending = new Map(), musicReads = new Map(); let sequence = 0, applying = false, installed = false, authKey = '', listKey = '', infoRequest, nativeAccount;
  let playback = {queue: [], index: -1, paused: true, position: 0, duration: 0};
  // Interpolate from the decoder's sample. A later UI packet may still
  // contain that same sample, so it cannot renew the extrapolation budget.
  const projectionLimit = 1.25;
  let clock = {position: 0, floor: 0, at: performance.now(), remaining: 0, running: false, rate: 1, correction: 0};
  let foregroundSync = false;
  function displayTime(now = performance.now()) {
    const elapsed = clock.running ? Math.max(0, Math.min(clock.remaining, (now - clock.at) / 1000)) : 0;
    const value = Math.max(clock.floor, clock.position + elapsed * clock.rate + clock.correction * Math.min(1, elapsed / 0.5));
    return playback.duration > 0 ? Math.min(playback.duration, value) : value;
  }
  function anchorClock(state, previous, positionSampledAt) {
    const now = performance.now(), projected = displayTime(now);
    const running = state.playing === true && !state.paused && !state.loading && !state.seeking;
    const rate = Number(state.playbackRate) > 0 ? Number(state.playbackRate) : 1;
    const transport = (Date.now() - Number(positionSampledAt)) / 1000;
    const elapsed = running && Number.isFinite(transport) ? Math.min(projectionLimit, Math.max(0, transport)) : 0;
    const position = Math.max(0, Number(state.position) || 0) + elapsed * rate;
    const sameTimeline = key(state.song) === key(previous.song) && state.timelineRevision === previous.timelineRevision;
    const continuous = sameTimeline && running && clock.running && !foregroundSync;
    const correction = position - projected;
    const remaining = projectionLimit - elapsed;
    const smooth = continuous && remaining > 0 && Math.abs(correction) < 0.15;
    // An estimate can run ahead during a short stall. Hold the visible clock
    // until the measured position catches up, and allow real seeks to reset it.
    clock = {position: smooth ? projected : position, floor: sameTimeline ? projected : 0,
      at: now, remaining, running, rate, correction: smooth ? correction : 0};
    foregroundSync = false;
  }
  let renderedQueue = -1, renderedSong = '', renderedQuality = '', selection = 0;
  let renderedPaused = null, renderedStatus = null, renderedMode = null;
  let roomMemberSignature = '';
  let room = {binding: null, state: {}, participants: [], connected: false, enabled: true, syncOnTrack: true};
  const post = (op, values = {}) => new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => {pending.delete(id); reject(new Error('App 暂未回应，请重新打开页面'));}, 45000);
    pending.set(id, {resolve, reject, timer});
    window.webkit.messageHandlers.lxNative.postMessage({id, op, ...values});
  });
  const warn = error => window.showError?.(error.message || String(error));
  const send = (op, values) => post(op, values).catch(warn);
  let lyricOffsets = {};
  try {lyricOffsets = JSON.parse(localStorage.getItem('lx_native_lyric_offsets_v1')) || {};} catch {}
  const lyricOffset = () => Number(lyricOffsets[key(playback.song)]) || 0;
  function alignLyrics() {
    if (typeof lyricPlayer === 'undefined' || !lyricPlayer) return;
    const time = (displayTime() + lyricOffset() / 1000) * 1000 + (Number(lyricPlayer.tags?.offset) || 0) + (Number(lyricPlayer.offset) || 0);
    if (clock.running) lyricPlayer.play(displayTime() * 1000);
    else {lyricPlayer.pause(); if (typeof syncLyricByLineNum === 'function') syncLyricByLineNum(lyricPlayer.lines?.length && time < lyricPlayer.lines[0].time ? -1 : lyricPlayer._findCurLineNum(time));}
  }
  window.LXNative = {request: post, lyricTime: () => displayTime() + lyricOffset() / 1000, getLyricOffset: lyricOffset,
    setLyricOffset(value) {const offset = Math.round(Math.max(-10000, Math.min(10000, Number(value) || 0)));lyricOffsets[key(playback.song)] = offset;const entries = Object.entries(lyricOffsets).slice(-200);lyricOffsets = Object.fromEntries(entries);localStorage.setItem('lx_native_lyric_offsets_v1', JSON.stringify(lyricOffsets));alignLyrics();return offset;}};
  const originalFetch = window.fetch?.bind(window);
  if (originalFetch) window.fetch = async function (input, options = {}) {
    const url = new URL(typeof input === 'string' ? input : input.url, location.href);
    const local = /^\/api\/music\/(?:config|search|tipSearch|hotSearch|artistDetail|artistAlbums|artistSongs|albumSongs|songList\/|leaderboard\/|lyric(?:$|\?)|pic(?:$|\?)|url(?:$|\?)|comment(?:$|\?))/.test(url.pathname) || url.pathname === '/api/custom-source/list';
    if (url.origin === location.origin && local) {
      try {
        const body = typeof options.body === 'string' ? JSON.parse(options.body) : {};
        const cacheable = (!options.method || options.method.toUpperCase() === 'GET') && /songList\/|hotSearch|leaderboard\/boards/.test(url.pathname);
        const readKey = url.pathname + url.search;
        let task = cacheable ? musicReads.get(readKey) : null;
        if (!task) {task = post('musicApi', {path: readKey, body});if (cacheable) {musicReads.set(readKey, task);task.then(() => musicReads.delete(readKey), () => musicReads.delete(readKey));}}
        const value = await task;
        return new Response(JSON.stringify(value), {status: 200, headers: {'Content-Type': 'application/json'}});
      } catch (error) { return new Response(JSON.stringify({error: error.message, message: error.message}), {status: 503, headers: {'Content-Type': 'application/json'}}); }
    }
    if (url.origin === location.origin && url.pathname.startsWith('/api/') && location.hostname === 'lx-device.invalid')
      return new Response(JSON.stringify({success: false, message: '此功能需要连接同步服务器'}), {status: 503, headers: {'Content-Type': 'application/json'}});
    return originalFetch(input, options);
  };
  const key = song => (song?.source || song?.meta?.source || '') + ':' + String(song?.songmid || song?.meta?.songmid || song?.meta?.songId || song?.mid || song?.id || `${song?.name || ''}-${song?.singer || song?.artist || ''}`);
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
    if (Number.isFinite(state.sampledAt) && Number.isFinite(playback.sampledAt) && state.sampledAt < playback.sampledAt) return;
    const previous = playback, updatedQueue = Array.isArray(state.queue);
    const positionSampledAt = state.positionSampledAt ?? state.sampledAt;
    playback = {...playback, ...state}; state = playback;
    anchorClock(state, previous, positionSampledAt);
    if (!installed) return;
    applying = true;
    try {
      // Match togglePlay while the decoder is loading, buffering or seeking.
      const paused = state.paused !== false;
      if (renderedPaused !== paused) {updatePlayButton(!paused); renderedPaused = paused;}
      if (updatedQueue || currentPlaylist !== state.queue && renderedQueue === -1) currentPlaylist = state.queue;
      currentIndex = state.index; playMode = state.mode || 'list';
      currentPlayingSong = state.song?.name ? state.song : null; window.currentPlayingSong = currentPlayingSong;
      requestedRoomSong = currentPlayingSong; roomAudioSongKey = key(currentPlayingSong);
      currentQuality = state.quality || null; playbackProgressReady = state.duration > 0;
      shouldAutoRecoverPlayback = !state.paused; currentLoadingSongId = null;
      const changedSong = key(state.song) !== renderedSong;
      const qualityLabel = state.quality && state.qualityReported === false ? '音质未确认' : state.quality;
      if (state.song?.name && (changedSong || renderedQuality !== qualityLabel)) { updatePlayerInfo(state.song, qualityLabel); renderedQuality = qualityLabel; }
      if (changedSong) {
        renderedSong = key(state.song);
        window.syncCommentSong?.();
        if (state.song?.name) {try {fetchLyric(state.song, state.quality); savePlayHistory(state.song, state.quality);} catch {}}
      }
      const playing = state.playing === true;
      const status = state.error || (state.loading ? '正在获取播放链接' : state.ended && !state.paused ? '等待房间下一首' : !state.paused && !playing ? '正在缓冲' : '');
      const statusKey = JSON.stringify([status, playing]);
      if (renderedStatus !== statusKey) {setPlayerStatus(status, playing); renderedStatus = statusKey;}
      const audio = audioElement();
      if (audio) {
        audio.dispatchEvent(new Event('timeupdate'));
        // Lyrics follow native playback; do not dispatch HTML play/pause recovery handlers.
        if (typeof lyricPlayer !== 'undefined' && lyricPlayer) {
          if (!clock.running) {
            lyricPlayer.pause();
            if (!state.seeking && (previous.seeking || state.timelineRevision !== previous.timelineRevision) && typeof syncLyricByLineNum === 'function')
              alignLyrics();
          }
          else {
            const time = displayTime() * 1000;
            const lyricTime = (displayTime() + lyricOffset() / 1000) * 1000 + (Number(lyricPlayer.tags?.offset) || 0) + (Number(lyricPlayer.offset) || 0);
            const drift = typeof lyricPlayer._currentTime === 'function' ? Math.abs(lyricPlayer._currentTime() - lyricTime) : 0;
            if (!previous.playing || previous.seeking || changedSong || state.timelineRevision !== previous.timelineRevision || drift > 150)
              lyricPlayer.play(time);
          }
        }
      }
      if (renderedMode !== state.mode && typeof updatePlayModeUI === 'function') {updatePlayModeUI(); renderedMode = state.mode;}
      if (typeof renderQueue === 'function' && updatedQueue && renderedQueue !== state.queueRevision) {
        renderQueue(); renderedQueue = state.queueRevision;
      } else if (renderedQueue === state.queueRevision && previous.index !== state.index &&
          !document.getElementById('queue-drawer')?.classList.contains('translate-x-full')) {
        const list = document.getElementById('queue-list');
        for (const index of [previous.index, state.index]) {
          const row = list?.children?.[index];
          if (!row?.hasAttribute('data-queue-index')) continue;
          const active = index === state.index;
          for (const name of ['t-bg-item-hover','border-l-4','border-emerald-500','pl-2']) row.classList.toggle(name,active);
          row.querySelector('.animate-ping')?.parentElement?.remove();
          const title = row.querySelector('.font-bold');
          title?.classList.toggle('text-emerald-500',active);title?.classList.toggle('t-text-main',!active);
        }
      }
      if (state.error) document.getElementById('lx-native-state')?.replaceChildren(document.createTextNode(state.error));
    } catch (error) { console.warn('[LX Native] UI update', error); }
    finally { applying = false; }
    window.dispatchEvent(new CustomEvent('lx-native-playback', {detail: state}));
  }
  function receiveRoom(state) {
    room = state;
    const get = id => document.getElementById(id);
    if (get('listen-room-status')) get('listen-room-status').textContent = room.binding ? `${room.binding.roomId} · ${room.connected ? room.participants.length + ' 位成员一起听' : '连接中…'}` : '和朋友分享同一段旋律';
    if (get('listen-room-roomid')) get('listen-room-roomid').textContent = room.binding?.roomId || '—';
    const signature = JSON.stringify([room.binding?.roomId,room.participants,room.state?.controllerId,room.owner]);
    if (signature !== roomMemberSignature && get('listen-room-participants')) {
      const container = get('listen-room-participants'); container.replaceChildren();
      for (const member of room.participants || []) {
        const row = document.createElement('div'); row.className = 'room-member';
        const label = document.createElement('span'); label.textContent = (member.id === room.state?.controllerId ? '♛ ' : '') + (member.nickname || member.name || '成员'); row.append(label); container.append(row);
      }
    }
    if (signature !== roomMemberSignature) {
      roomMemberSignature = signature;
      window.dispatchEvent(new CustomEvent('lx-room-members-change', {detail: {participants: room.participants || [], controllerId: room.state?.controllerId || '', owner: room.owner || '', roomId: room.binding?.roomId || ''}}));
    }
    window.dispatchEvent(new CustomEvent('lx-native-room', {detail: room}));
  }
  window.LXBridge = {
    reply(id, value, error) {const item = pending.get(id); if (!item) return; pending.delete(id); clearTimeout(item.timer); error ? item.reject(new Error(error)) : item.resolve(value);},
    publishLibrary, state: receiveState, room: receiveRoom, getPlayback: () => playback, getRoom: () => room, getAccountInfo: () => nativeAccount,
    prepareDevice(song, ticket) {
      prepareDevice(song).then(() => send('devicePrepared', {ticket}),
        error => send('devicePrepared', {ticket,error:error.message || '无法读取设备文件'}));
      return true;
    },
    appInfo: () => infoRequest ||= post('appInfo').catch(error => {infoRequest = null; throw error;}),
    isReady: () => installed && document.readyState !== 'loading' && !!window.NativeShell?.ready && Number.isFinite(playback.sampledAt),
    server(value) {
      nativeAccount = value; infoRequest = null;
      const label = document.querySelector('.lx-server-address');
      if (label) label.textContent = value.server;
      window.dispatchEvent(new CustomEvent('lx-native-server', {detail: value}));
    },
    keyboard(value) {window.dispatchEvent(new CustomEvent('lx-native-keyboard', {detail:value}));},
    download(value) {window.dispatchEvent(new CustomEvent('lx-native-download', {detail: value}));},
    sources(value) {window.dispatchEvent(new CustomEvent('lx-native-sources', {detail: value}));},
    chat(type, data) {window.dispatchEvent(new CustomEvent(type === 'room:chat-history' ? 'lx-room-chat-history' : 'lx-room-chat-update', {detail: {...data, roomId: room.binding?.roomId || ''}}));}
  };
  let libraryQueue = Promise.resolve();
  function publishLibrary(data) {
    const lists = [{id:'love',name:'我的收藏',list:data.loveList||[]},{id:'default',name:'默认列表',list:data.defaultList||[]},...(data.userList||[])];
    const serialized = JSON.stringify(lists), owner=authKey;
    const job = libraryQueue.catch(()=>{}).then(async()=>{
      if (owner!==authKey || serialized === listKey) return;
      await post('library',{lists}); listKey = serialized;
    });
    libraryQueue = job; return job;
  }
  function preferences() {
    try { return {quality: settings.preferredQuality || 'flac', allowFallback: settings.enableAutoDegradeQuality !== false, mode: playMode || 'list'}; }
    catch { return {quality: 'flac', allowFallback: true, mode: 'list'}; }
  }
  function clearWebSession() {
    for (const key of ['lx_user_token', 'lx_web_token_user', 'lx_sync_pass', 'lx_sync_user', 'lx_sync_mode'])
      localStorage.removeItem(key);
    authKey = ''; listKey = '';
  }
  async function restoreAccount() {
    let account = await post('session');
    if (!account.revoked && account.migrate && localStorage.getItem('lx_user_token')) {
      const username = localStorage.getItem('lx_sync_user') || '', token = localStorage.getItem('lx_user_token');
      const owner = localStorage.getItem('lx_web_token_user');
      if ((!owner || owner === username) && await post('auth', {username, token})) account = {username, token};
    }
    if (account.info) window.LXBridge.server(account.info);
    if (account.token) {
      authKey = account.username; infoRequest = null;
      localStorage.setItem('lx_sync_user', account.username);
      localStorage.setItem('lx_user_token', account.token);
      localStorage.setItem('lx_web_token_user', account.username);
      localStorage.setItem('lx_sync_mode', 'local');
      localStorage.removeItem('lx_sync_pass');
      window.SyncManager?.initLocal(account.username, '');
      if (typeof notifyAccountChange === 'function') notifyAccountChange();
    } else {
      if (localStorage.getItem('lx_sync_user') !== '__device__') clearWebSession();
      if (account.revoked) window.dispatchEvent(new CustomEvent('lx-auth-revoked'));
    }
    return account;
  }
  const originalSet = Storage.prototype.setItem;
  Storage.prototype.setItem = function (key, value) {
    originalSet.call(this, key, value);
    if (this === localStorage && installed && ['lx_settings', 'lx_play_mode'].includes(key))
      queueMicrotask(() => send('preferences', preferences()));
  };
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
    } catch (error) {await post('importCancel', {ticket: opened.ticket}).catch(()=>{}); throw error;}
  }
  const deviceImports = new Map();
  let deviceTransfer = Promise.resolve();
  function prepareDevice(song) {
    if (deviceImports.has(song.deviceKey)) return deviceImports.get(song.deviceKey);
    const task = deviceTransfer.catch(()=>{}).then(()=>importDevice(song)).then(()=>true);
    deviceImports.set(song.deviceKey,task);
    task.then(()=>deviceImports.delete(song.deviceKey),()=>deviceImports.delete(song.deviceKey));
    deviceTransfer = task;
    return task;
  }
  async function select(song, index, quality, noPlay) {
    if (noPlay) return;
    const request = ++selection;
    let queue = window.__LX_PLAYER_GETTERS__?.getCurrentPlaylist?.()?.slice() || [song];
    let at = Number.isInteger(index) && key(queue[index]) === key(song) ? index : queue.findIndex(item => key(item) === key(song));
    if (at < 0) {queue = [song]; at = 0;}
    await post('select', {queue, index: at, ...preferences(), ...(quality ? {quality} : {})});
    if (request === selection) window.MobileShell?.openOnPlay?.();
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
    // A font-size transition changes every following line's position while scrolling.
    // Keep line metrics stable; animate only the visual emphasis.
    if (document.head) {
      const style = document.createElement('style'); style.id = 'lx-native-lyrics';
      style.textContent = `html[data-native-app] .lyric-line {
        font-size: var(--lyric-font-size, 1.25rem); font-weight: 700;
        transition: opacity .32s ease, color .32s ease, transform .4s ease;
      }
      html[data-native-app] .lyric-line.active {font-size: var(--lyric-font-size, 1.25rem); font-weight: 700; transform: scale(1.06);}`;
      document.head.append(style);
    }
    const audio = audioElement();
    if (audio) {
      let deviceVolume = Number(audio.volume) || 1, deviceMuted = !!audio.muted;
      const properties = {volume: {get: () => deviceVolume, set: value => {deviceVolume = Math.max(0, Math.min(1, Number(value))); if (!applying) send('volume', {volume: deviceVolume, muted: deviceMuted});}}, muted: {get: () => deviceMuted, set: value => {deviceMuted = !!value; if (!applying) send('volume', {volume: deviceVolume, muted: deviceMuted});}}, currentTime: {get: displayTime, set: value => {if (!applying) send('seek', {time: Number(value)});}}, duration: {get: () => playback.duration || NaN}, paused: {get: () => playback.paused !== false || playback.playing === false}, ended: {get: () => !!playback.ended}, readyState: {get: () => playback.duration > 0 ? 4 : 0}, seeking: {get: () => !!playback.seeking}};
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
      const title = document.createElement('h3'); title.textContent = '栖页音乐'; card.append(title);
      const label = document.createElement('p'); label.id = 'lx-native-state'; label.textContent = '内置界面 · 原生播放 · CarPlay'; card.append(label);
      const address = document.createElement('p'); address.className = 'lx-server-address'; card.append(address);
      const button = document.createElement('button'); button.type = 'button'; button.className = 'apple-secondary'; button.textContent = '更换音乐服务器'; button.onclick = () => send('editServer'); card.append(button);
      const version = document.createElement('p'); version.className = 'lx-app-version'; card.append(version); settingsView.prepend(card);
      window.LXBridge.appInfo().then(info => {address.textContent = info.server || ''; version.textContent = 'App ' + info.version + ' · 内置界面 ' + (window.CONFIG?.version || '');}).catch(warn);
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
    window.LXBridge.accountReady = restoreAccount();
    window.LXBridge.accountReady.catch(warn);
    window.LXBridge.signOut = () => {clearWebSession(); return post('signOut');};
    const fetchPlayback = () => post('ready').then(value => {
      if (value?.state) receiveState(value.state);
      if (value?.room) receiveRoom(value.room);
    }).catch(warn);
    fetchPlayback().then(()=>send('preferences', preferences()));
    receiveState(playback); receiveRoom(room);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') {foregroundSync = true; fetchPlayback();}
      else {clock = {...clock, position: displayTime(), at: performance.now(), running: false, correction: 0};}
    });
    const reportUIReady = async(attempt = 0) => {
      const proof = {nativeSnapshot:Number.isFinite(playback.sampledAt),
        compactLayout:!!document.getElementById('view-player-detail')?.classList.contains('hidden')&&!document.body.classList.contains('mobile-player-open'),
        bundled: window.__LX_BUNDLED_UI__ === true, mobile: !!window.MobileShell, themes: !!window.DesktopLayout, localShell: !!window.NativeShell,
        navigation: [...document.querySelectorAll('#mobile-bottom-nav button')].map(button=>(button.querySelector('span')||button).textContent.trim()),roomChat:!!document.getElementById('view-native-room')&&!!document.getElementById('room-chat-input'),mine:!!document.getElementById('native-mine-grid'),downloads:!!document.getElementById('view-native-downloads')};
      try {if (await post('uiReady', proof) === false && attempt < 40) setTimeout(() => reportUIReady(attempt + 1), 250);} catch (error) {warn(error);}
    };
    setTimeout(reportUIReady, 120);

  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install); else install();
})();
