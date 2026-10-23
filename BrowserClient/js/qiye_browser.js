/* Connect the shared IPA presentation to the existing browser audio and APIs. */
(function(){
'use strict';
if(window.webkit?.messageHandlers?.lxNative)return;
var $=function(id){return document.getElementById(id);},roomSignature='',sources=[],profile={},lastIdentity='';
document.documentElement.dataset.nativeApp='true';
document.documentElement.dataset.qiyeWeb='true';
function auth(){return Object.assign({},window.getUserAuthHeaders?.() || window.DeviceLibrary?.ownAuth?.() || {});}
function username(){return localStorage.getItem('lx_sync_user') || auth()['x-user-name'] || '';}
function identity(){return JSON.stringify([username(),auth()['x-user-token'] || '']);}
async function api(path,body){
 var before=identity(),options={credentials:'same-origin',cache:'no-store',headers:auth()};
 if(body!==undefined){options.method='POST';options.headers['Content-Type']='application/json';options.body=JSON.stringify(body);}
 var response=await fetch(path,options),value=await response.json().catch(function(){return {};});
 if(before!==identity())throw new Error('账号已切换，请重新操作');
 if(!response.ok || value.success===false)throw new Error(value.message || value.error || '请求失败 ('+response.status+')');
 return value;
}
function logged(){return !!auth()['x-user-token'];}
function appInfo(){return {version:'2.9.3',server:location.origin,username:username(),hasAccount:logged(),bundledUI:false,legacySourceFallback:true,browser:true};}
function roomChanged(){
 var raw=window.ListenRoom?.debugState?.() || {},value={
  binding:window.ListenRoom?.getBinding?.() || null,participants:raw.participants || [],state:raw.state || {},
  participantId:raw.participantId || '',owner:raw.owner || '',connected:!!window.ListenRoom?.isConnected?.(),
  enabled:raw.enabled!==false,syncOnTrack:raw.syncOnTrack!==false
 };
 var signature=JSON.stringify([value.binding,value.participants,value.participantId,value.owner,value.connected,value.enabled,value.syncOnTrack,value.state.controllerId]);
 if(signature===roomSignature)return value;roomSignature=signature;
 window.dispatchEvent(new CustomEvent('lx-native-room',{detail:value}));return value;
}
function playbackChanged(){
 var audio=$('audio-player'),player=window.__LX_PLAYER_GETTERS__,song=window.currentPlayingSong || player?.getRoomSong?.();
 window.dispatchEvent(new CustomEvent('lx-native-playback',{detail:{song:song,paused:!audio || audio.paused,playing:!!audio && !audio.paused && !audio.ended,
  position:audio?.currentTime || 0,duration:Number.isFinite(audio?.duration)?audio.duration:0,mode:player?.getPlayMode?.() || 'list'}}));
}
async function membership(values){
 if(!logged())throw new Error('请先登录同步账号');
 if(values.operation==='leave'){
  await api('/api/room/leave',{});window.ListenRoom?.disconnect?.();return roomChanged();
 }
 if(!['create','join'].includes(values.operation))throw new Error('未知房间操作');
 await api('/api/room/'+values.operation,{roomId:String(values.roomId || '').trim(),password:values.password || ''});
 await window.ListenRoom.refreshBinding(true);return roomChanged();
}
async function sourceList(){
 if(!logged() && !auth()['x-frontend-auth'])return [];
 var value=await api('/api/custom-source/list?username='+encodeURIComponent(username() || 'default'));
 sources=(Array.isArray(value)?value:value.sources || value.data || []).map(function(s){return Object.assign({},s,{enabled:s.enabled!==false && !s.disabled,canRemove:!s.isPublic || !!auth()['x-frontend-auth']});});
 return sources;
}
function sourceUpload(){
 if(!logged() && !auth()['x-frontend-auth'])return Promise.reject(new Error('请先登录账号后管理音源'));
 return new Promise(function(resolve,reject){
  var input=document.createElement('input');input.type='file';input.accept='.js,text/javascript,application/javascript';input.hidden=true;document.body.append(input);
  input.onchange=async function(){
   try{var file=input.files[0];if(!file){resolve(false);return;}if(file.size>2*1024*1024)throw new Error('音源文件不能超过 2 MiB');
    await api('/api/custom-source/upload',{username:username() || 'open',filename:file.name,content:await file.text()});resolve(true);
   }catch(error){reject(error);}finally{input.remove();}
  };
  input.addEventListener('cancel',function(){input.remove();resolve(false);},{once:true});input.click();
 });
}
function signIn(){
 window.NativeShell?.go('settings');
 var local=$('btn-mode-local');local?.click();
 requestAnimationFrame(function(){$('sync-local-user')?.scrollIntoView({block:'center',behavior:'smooth'});$('sync-local-user')?.focus({preventScroll:true});});
 return true;
}
var offsets;
function songKey(){
 var song=window.currentPlayingSong || {};
 return [username() || '_guest',song.source || '',song.songmid || song.id || song.name || ''].join(':');
}
function readOffsets(){if(!offsets){try{offsets=JSON.parse(localStorage.getItem('qiye_lyric_offsets_v1')) || {};}catch{offsets={};}}return offsets;}
function offset(){return Number(readOffsets()[songKey()]) || 0;}
function align(){
 try{if(typeof lyricPlayer!=='undefined' && lyricPlayer){
  lyricPlayer.offset=offset();var a=$('audio-player');
  if(a && !a.paused)lyricPlayer.play(a.currentTime*1000);
  else if(a){lyricPlayer.pause();var now=a.currentTime*1000+offset()+(Number(lyricPlayer.tags?.offset)||0);if(typeof syncLyricByLineNum==='function')syncLyricByLineNum(lyricPlayer._findCurLineNum(now));}
 }}catch(error){console.warn('[Qiye lyrics]',error.message);}
}
function setOffset(value){
 var amount=Math.round(Math.max(-10000,Math.min(10000,Number(value)||0))),map=readOffsets();map[songKey()]=amount;
 offsets=Object.fromEntries(Object.entries(map).slice(-200));localStorage.setItem('qiye_lyric_offsets_v1',JSON.stringify(offsets));align();return amount;
}
async function request(op,values){
 values=values || {};
 switch(op){
  case 'appInfo':return appInfo();
  case 'downloads':return window.QiyeOffline.list();
  case 'download':return window.QiyeOffline.add(values.song,values.quality,values.parts);
  case 'downloadRemove':return window.QiyeOffline.remove(values.downloadId);
  case 'downloadCancel':return window.QiyeOffline.cancel(values.downloadId);
  case 'downloadAssets':return window.QiyeOffline.assets(values.downloadId);
  case 'playDownload':return window.QiyeOffline.play(values.downloadId);
  case 'shareDownload':return window.QiyeOffline.share(values.downloadId);
  case 'importAudio':return window.QiyeOffline.chooseImport();
  case 'sources':case 'serverSources':return sourceList();
  case 'importSource':return sourceUpload();
  case 'importSourceURL':{
   var url=new URL(values.url);if(!['https:','http:'].includes(url.protocol))throw new Error('请填写 HTTP(S) 音源链接');
   return api('/api/custom-source/import',{username:username() || 'open',url:url.href});
  }
  case 'sourceEnable':return api('/api/custom-source/toggle',{username:username() || 'open',id:values.sourceId,enabled:!!values.enabled});
  case 'sourceRemove':return api('/api/custom-source/delete',{username:username() || 'open',id:values.sourceId});
  case 'sourcePreferences':return {legacySourceFallback:true};
  case 'roomMembership':return membership(values);
  case 'roomRefresh':await window.ListenRoom?.refreshBinding?.(true);return roomChanged();
  case 'library':return true; // Existing ListStore/user_sync remains authoritative.
  case 'editServer':case 'signIn':return signIn();
  case 'signOut':return window.handleSyncLogout(true);
  default:throw new Error('此浏览器不支持操作：'+op);
 }
}
window.LXNative={runtime:'browser',request:request,lyricTime:function(){return ($('audio-player')?.currentTime || 0)+offset()/1000;},getLyricOffset:offset,setLyricOffset:setOffset};
window.QiyeWeb={roomChanged:roomChanged,playbackChanged:playbackChanged,api:api};
window.addEventListener('lx-room-members-change',roomChanged);
window.addEventListener('lx-profile-change',function(event){profile=event.detail || {};});
window.addEventListener('lx-auth-change',function(){
 var next=identity();if(next!==lastIdentity){lastIdentity=next;profile={};roomSignature='';}
 roomChanged();
});
window.addEventListener('qiye-shell-ready',function(){
 document.documentElement.removeAttribute('data-qiye-boot');
 var detail=window.LibraryHub.detail;
 window.LibraryHub.detail=function(){var result=detail.apply(this,arguments),back=$('personal-playlist-hero')?.querySelector('.playlist-back');if(back){back.textContent='‹';back.setAttribute('aria-label','返回上一页');}return result;};
 var favorites=window.LibraryHub.favorites;
 window.LibraryHub.favorites=function(){
  if(window.__LX_LIBRARY_GETTERS__?.getData?.())return favorites.apply(this,arguments);
  window.switchTab('search');window.LibraryHub.detail('love');
  $('page-title').textContent='我的收藏';window.renderResults([]);
  $('search-results').innerHTML='<p class="native-empty">登录账号后，可查看和同步我的收藏。</p>';
  $('search-pagination-bar').classList.add('hidden');
 };
 var fetchLyrics=window.fetchLyric;
 if(fetchLyrics)window.fetchLyric=async function(){var result=await fetchLyrics.apply(this,arguments);align();return result;};
 var audio=$('audio-player');
 if(audio)for(var type of ['play','pause','loadedmetadata','timeupdate','ended','emptied'])audio.addEventListener(type,playbackChanged);
 var footer=$('player-song-info');footer?.addEventListener('click',function(event){
  if(!event.target.closest('button,a,[onclick*="toggleLyrics"]') && window.currentPlayingSong && !matchMedia('(max-width:767px), (max-width:1024px) and (pointer:coarse)').matches)window.toggleLyrics();
 });
 var toggle=$('native-legacy-source');if(toggle)toggle.disabled=true;
 roomSignature='';roomChanged();playbackChanged();
});
})();
