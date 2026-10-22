
window.__LX_COMPONENT_RELEASES__=window.__LX_COMPONENT_RELEASES__ || {};
window.__LX_COMPONENT_RELEASES__['js/library_hub.js']='2.9.1';
(function(){
'use strict';
const $=id=>document.getElementById(id),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const data=()=>window.__LX_LIBRARY_GETTERS__?.getData?.();
let syncing=false,epoch=0;
const artPending=new Map();
function artwork(image,list){
  const normalize=value=>window.DeviceLibrary?.imageSource?.(value) || value;
  const candidates=[...new Set([list.Album,list.cover,list.picUrl,list.info?.img,...(list.list || []).slice(0,24).map(s=>s.meta?.picUrl || s.meta?.img || s.img || s.picUrl || s.pic),list.list?.[0] && window.getImgUrl?.(list.list[0])].filter(v=>typeof v==='string' && v && !/logo\.svg/.test(v)).map(normalize))];
  let next=0,asked=false;const owner=window.DeviceLibrary?.identity();
  image.referrerPolicy='no-referrer';
  const fallback=async()=>{if(next<candidates.length){image.src=candidates[next++];return;}if(!asked && list.list?.length){asked=true;try{const key=owner+':'+list.id;let pending=artPending.get(key);if(!pending){pending=window.DeviceLibrary.api('/api/user/playlist-art',{listId:list.id,refresh:true}).finally(()=>{if(artPending.get(key)===pending)artPending.delete(key);});artPending.set(key,pending);}const result=await pending;if(owner!==window.DeviceLibrary.identity() || !image.isConnected)return;const resolved=normalize(result.cover);if(result.cover && !candidates.includes(resolved)){image.src=resolved;return;}}catch{}}
    image.onerror=null;image.src='data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDI0IDEwMjQiPjxkZWZzPjxsaW5lYXJHcmFkaWVudCBpZD0iYiIgeDI9IjEiIHkyPSIxIj48c3RvcCBzdG9wLWNvbG9yPSIjMGQyNTJhIi8+PHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9yPSIjMTkzZjQyIi8+PC9saW5lYXJHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCIgcng9IjIyNCIgZmlsbD0idXJsKCNiKSIvPjxnIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2VkZTZkMCIgc3Ryb2tlLXdpZHRoPSIxOSIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTI1MCA2NjBDMjUwIDU0NSAyNTAgNDMwIDI1MCAzMTVDMzQ1IDMwNSA0MzAgMzMyIDUwNCAzOTJDNTA0IDUwMCA1MDQgNjEwIDUwNCA3MjZDNDI0IDY3MSAzNDQgNjUxIDI1MCA2NjBaIi8+PHBhdGggZD0iTTUyOCA3MjZDNTI4IDYxMCA1MjggNTAzIDUyOCAzOTJDNjAyIDMzMiA2ODggMzA1IDc4MiAzMTVDNzgyIDQzMCA3ODIgNTQ1IDc4MiA2NjBDNjg3IDY1MSA2MDcgNjcxIDUyOCA3MjZaIi8+PHBhdGggc3Ryb2tlLXdpZHRoPSIyMSIgZD0iTTUwNCA0MTVWNjI3Ii8+PC9nPjxwYXRoIGZpbGw9IiNiZGM0YTAiIGQ9Ik01ODAgMzUyQzU4OSAyNTIgNjc3IDIxNyA3NTkgMjIwQzc0NSAzMTIgNjg4IDM2NSA1ODAgMzUyWiIvPjxlbGxpcHNlIGN4PSI0NjUiIGN5PSI2MjcuNSIgcng9IjQ0IiByeT0iMjkuNSIgZmlsbD0iI2VkZTZkMCIvPjwvc3ZnPgo=';image.closest('.playlist-poster')?.classList.add('poster-fallback');};
  image.onerror=fallback;image.onload=()=>{const poster=image.closest('.playlist-poster');poster?.classList.add('poster-loaded');if(!image.src.includes('logo.svg'))poster?.classList.remove('poster-fallback');};fallback();
}
function menu(list,event){event.preventDefault();window.MusicContext.open(event,[{label:'打开歌单',action:()=>window.handleListClick(list.id)},...(list.id!=='default'?[{label:'编辑名称',action:()=>window.handleRenameList(list.id)},{label:'删除歌单',action:()=>window.handleRemoveList(list.id)}]:[]),{label:'分享到房间聊天',action:()=>window.RoomSocial.share(list.id)},{label:'创建分享链接',action:()=>window.ShareHub.choose({listId:list.id,title:list.name,songs:list.list})}]);}
function lists(){const d=data();if(!d)return [];const items=[{id:'default',name:'默认列表',list:d.defaultList || []},...(d.userList || [])],order=window.settings?.favoriteSidebarOrder || [];return items.sort((a,b)=>{const i=order.indexOf(a.id),j=order.indexOf(b.id);return (i<0?order.length:i)-(j<0?order.length:j);});}
function subscribed(list){return !!(list.subscription || (list.source && list.sourceListId));}
function cover(list){const raw=list.Album || list.cover || (list.list?.[0] && window.getImgUrl(list.list[0])) || 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMDI0IDEwMjQiPjxkZWZzPjxsaW5lYXJHcmFkaWVudCBpZD0iYiIgeDI9IjEiIHkyPSIxIj48c3RvcCBzdG9wLWNvbG9yPSIjMGQyNTJhIi8+PHN0b3Agb2Zmc2V0PSIxIiBzdG9wLWNvbG9yPSIjMTkzZjQyIi8+PC9saW5lYXJHcmFkaWVudD48L2RlZnM+PHJlY3Qgd2lkdGg9IjEwMjQiIGhlaWdodD0iMTAyNCIgcng9IjIyNCIgZmlsbD0idXJsKCNiKSIvPjxnIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2VkZTZkMCIgc3Ryb2tlLXdpZHRoPSIxOSIgc3Ryb2tlLWxpbmVqb2luPSJyb3VuZCI+PHBhdGggZD0iTTI1MCA2NjBDMjUwIDU0NSAyNTAgNDMwIDI1MCAzMTVDMzQ1IDMwNSA0MzAgMzMyIDUwNCAzOTJDNTA0IDUwMCA1MDQgNjEwIDUwNCA3MjZDNDI0IDY3MSAzNDQgNjUxIDI1MCA2NjBaIi8+PHBhdGggZD0iTTUyOCA3MjZDNTI4IDYxMCA1MjggNTAzIDUyOCAzOTJDNjAyIDMzMiA2ODggMzA1IDc4MiAzMTVDNzgyIDQzMCA3ODIgNTQ1IDc4MiA2NjBDNjg3IDY1MSA2MDcgNjcxIDUyOCA3MjZaIi8+PHBhdGggc3Ryb2tlLXdpZHRoPSIyMSIgZD0iTTUwNCA0MTVWNjI3Ii8+PC9nPjxwYXRoIGZpbGw9IiNiZGM0YTAiIGQ9Ik01ODAgMzUyQzU4OSAyNTIgNjc3IDIxNyA3NTkgMjIwQzc0NSAzMTIgNjg4IDM2NSA1ODAgMzUyWiIvPjxlbGxpcHNlIGN4PSI0NjUiIGN5PSI2MjcuNSIgcng9IjQ0IiByeT0iMjkuNSIgZmlsbD0iI2VkZTZkMCIvPjwvc3ZnPgo=';return window.DeviceLibrary?.imageSource?.(raw) || raw;}
async function show(){if(window.isViewingPublicFavorites)await window.handleTogglePublicFavorites();window.switchTab('playlists');render();}
function render(){
  const grid=$('personal-playlists-grid');if(!grid)return;
  const signature=JSON.stringify([window.DeviceLibrary?.identity?.(),lists().map(l=>[l.id,l.name,l.list.length,cover(l),subscribed(l),(l.list || []).slice(0,24).map(s=>s.meta?.picUrl || s.meta?.img || s.img || s.picUrl || s.pic)] )]);
  if(grid._posterSignature===signature)return;grid._posterSignature=signature;grid.replaceChildren();
  for(const list of lists()){
    const card=document.createElement('article');card.className='personal-playlist-card';
    card.dataset.playlistId=list.id;
    card.innerHTML=`<button class="personal-playlist-open" title="${esc(list.name)}"><span class="playlist-poster"><img src="${esc(cover(list))}" alt="" loading="lazy"></span><strong>${esc(list.name)}</strong><small>${list.list.length} 首歌曲${subscribed(list)?' · ↻ 订阅同步':''}</small></button>`;
    artwork(card.querySelector('img'),list);
    card.oncontextmenu=e=>menu(list,e);window.MusicContext.bindTouch(card,e=>menu(list,e));
    card.onkeydown=e=>{if(e.key==='ContextMenu' || e.shiftKey && e.key==='F10')menu(list,e);};
    card.querySelector('.personal-playlist-open').onclick=()=>window.handleListClick(list.id);
    grid.append(card);
  }
  if(!lists().length)grid.innerHTML='<p class="media-empty">登录后，你的歌单会显示在这里。</p>';
  // Personal playlists are always posters, including the first paint. Sorting
  // moves to the posters while public favorites, artists and albums stay in
  // the existing favorites group.
  if(window.Sortable && !grid._playlistSortable)grid._playlistSortable=window.Sortable.create(grid,{animation:160,draggable:'.personal-playlist-card',delay:350,delayOnTouchOnly:true,touchStartThreshold:8,onEnd:()=>{
    const ids=[...grid.children].map(c=>c.dataset.playlistId).filter(Boolean),old=window.settings?.favoriteSidebarOrder || [];
    window.persistFavoriteSidebarOrder?.([...old.filter(id=>!ids.includes(id)),...ids]);
  }});
}
async function favorites(){if(window.isViewingPublicFavorites)await window.handleTogglePublicFavorites();window.handleListClick('love');}
function detail(listId){
  const d=window.__LX_LIBRARY_GETTERS__?.getViewingData?.() || data(),list=listId==='love'?{id:'love',name:'我的收藏',list:d?.loveList || []}:listId==='default'?{id:'default',name:'默认列表',list:d?.defaultList || []}:d?.userList?.find(x=>x.id===listId);
  const hero=$('personal-playlist-hero');if(!hero)return;
  if(!list){hideDetail();return;}hero.classList.remove('hidden');$('view-search').classList.add('is-playlist-detail');
  const signature=JSON.stringify([window.DeviceLibrary?.identity?.(),listId,list.name,list.list.length,cover(list),subscribed(list)]);
  if(hero._detailSignature!==signature){hero._detailSignature=signature;
  hero.innerHTML=`<button class="playlist-back apple-link" aria-label="返回上一页">‹</button><img class="personal-playlist-cover" src="${esc(cover(list))}" alt=""><div class="personal-playlist-description"><small>${listId==='love'?'我的收藏':'我的歌单'}</small><h1>${esc(list.name)}</h1><p>${list.list.length} 首歌曲${subscribed(list)?' · ↻ 持续订阅同步':''}</p><div class="media-actions"><button class="apple-primary" data-action="play">播放全部</button><button class="apple-secondary" data-action="download" aria-label="下载整个歌单"><span class="playlist-wide-label">下载整个歌单</span><span class="playlist-compact-label">下载</span></button><button class="apple-secondary" data-action="share">分享</button>${listId!=='love' && listId!=='default' || subscribed(list)?'<button class="apple-secondary" data-action="more" aria-label="更多歌单选项">•••</button>':''}</div><p class="playlist-subscription-status" id="playlist-subscription-status"></p></div>`;
  artwork(hero.querySelector('img'),list);hero.querySelector('.playlist-back').onclick=()=>window.NativeShell?window.NativeShell.back():show();
  const actions={play:()=>{if(!list.list.length)return;window.__LX_PLAYER_GETTERS__.setRoomPlaylist(list.list,0);window.playSong(list.list[0],0);},download:()=>window.DeviceLibrary.downloadBatch(list.list),share:()=>window.ShareHub.choose({listId,title:list.name,songs:list.list}),rename:()=>window.handleRenameList(listId),export:()=>window.exportPlaylistToLocal(listId),remove:()=>window.handleRemoveList(listId),sync:()=>window.LibrarySync.run({listId}),unsubscribe:async()=>{
    if(list.subscription?.type==='room')await window.DeviceLibrary.api('/api/user/subscriptions/remove',{listId});
    delete list.subscription;delete list.sourceListId;await window.__LX_LIBRARY_GETTERS__.save();render();detail(listId);window.showSuccess?.('已转为独立歌单');
  }};
  actions.more=()=>window.MusicContext.open({currentTarget:hero.querySelector('[data-action=more]')},[...(listId!=='love' && listId!=='default'?[{label:'编辑名称',action:actions.rename},{label:'导出歌单',action:actions.export},{label:'删除歌单',action:actions.remove}]:[]),...(subscribed(list)?[{label:'立即同步',action:actions.sync},{label:'取消订阅',action:actions.unsubscribe}]:[])]);
  for(const b of hero.querySelectorAll('[data-action]'))b.onclick=()=>Promise.resolve(actions[b.dataset.action]()).catch(e=>window.showError?.(e.message));
  }
  const tab=$('tab-playlists');if(tab && listId!=='love'){document.querySelectorAll('[id^=tab-]').forEach(t=>t.classList.remove('active-tab'));tab.classList.add('active-tab');}
}
function hideDetail(){ $('personal-playlist-hero')?.classList.add('hidden');$('view-search')?.classList.remove('is-playlist-detail'); }
async function sync(notify=false){
  if(notify)return window.LibrarySync.run().catch(()=>{});
  if(window.LibrarySync?.isRunning() || syncing || !window.getUserAuthHeaders?.()['x-user-token'])return;syncing=true;const version=epoch,revision=window.LibrarySync?.revision();
  try {
    const result=await window.DeviceLibrary.api('/api/user/subscriptions');if(version!==epoch || revision!==window.LibrarySync?.revision())return;
    // Adopt only the subscription rows: never replace unrelated unsaved edits.
    window.__LX_LIBRARY_GETTERS__.adoptSubscriptions(result.data,result.subscriptions);
    render();window.LibrarySync?.refreshView();await window.LibrarySync?.nativeLibrary(data());const current=window.currentViewingListId;
    if(current && !$('view-search').classList.contains('hidden') && result.subscriptions[current]){detail(current);const status=$('playlist-subscription-status');if(status)status.textContent=result.subscriptions[current].error || '已同步 · '+new Date(result.subscriptions[current].updatedAt).toLocaleTimeString();}
    if(notify)window.showSuccess?.('订阅歌单已同步');
  }catch(error){if(notify)window.showError?.(error.message);}finally{syncing=false;}
}
async function fullPlatformList(detail){
  let songs=[...(detail.list || [])];
  const first=await fetch('/api/music/songList/detail?'+new URLSearchParams({source:detail.source,id:detail.id,page:1}),{cache:'no-store'}).then(r=>{if(!r.ok)throw new Error('歌单读取失败');return r.json();});
  if(!Array.isArray(first.list))throw new Error('歌单数据无效');songs=first.list;
  const pageSize=first.list.length,total=Number(first.total || first.info?.total)||pageSize;
  if(total>20000)throw new Error('歌单超过 20000 首，请分批保存');
  for(let page=2;pageSize && songs.length<total;page++){
    const response=await fetch('/api/music/songList/detail?'+new URLSearchParams({source:detail.source,id:detail.id,page}),{cache:'no-store'});const data=await response.json();
    if(!response.ok || !Array.isArray(data.list) || !data.list.length)throw new Error('歌单未加载完整，请重试');songs=songs.concat(data.list);
  }
  if(songs.length<total)throw new Error('歌单未加载完整，请重试');
  return {...detail,info:window.SongListManager.normalizeInfo({...detail.info,...first.info}),list:songs.map(song=>({...song,source:song.source || detail.source}))};
}
async function collectPlatform(){
  const original=window.SongListManager?.getCurrentDetail?.();if(!original)return;
  const mode=await window.showOptions('保存歌单','保存当前内容，或持续同步原平台歌单',['保存当前副本','订阅歌单']);if(!mode)return;
  const version=epoch;window.showInfo?.('正在读取完整歌单…');
  try {const detail=await fullPlatformList(original);if(version!==epoch)return;
    const item={id:'platform_'+window.DeviceLibrary.uuid(),name:detail.info?.name || '未命名歌单',Album:detail.info?.img || detail.info?.pic || '',source:detail.source,list:detail.list.map(s=>window.formatSongToLxMusicStandard({...s,source:s.source || detail.source})),locationUpdateTime:Date.now(),...(mode==='订阅歌单'?{sourceListId:String(detail.id),subscription:{type:'platform',source:detail.source,id:String(detail.id)}}:{})};
    await window.__LX_LIBRARY_GETTERS__.addList(item);render();window.showSuccess?.(mode==='订阅歌单'?'已订阅歌单':'已保存完整副本');
  }catch(error){window.showError?.(error.message);}
}
const platformBusy=new Set();
async function platformAction(action){
  const detail=window.SongListManager?.getCurrentDetail?.();if(!detail?.info || platformBusy.has(action))return;
  const version=epoch,button=$('sl-detail-'+action);platformBusy.add(action);if(button)button.disabled=true;
  window.showInfo?.('正在读取完整歌单…');
  try{
    const all=await fullPlatformList(detail),current=window.SongListManager.getCurrentDetail();
    if(version!==epoch || current?.id!==detail.id || current?.source!==detail.source || !current?.info)return;
    if(action==='download')await window.DeviceLibrary.downloadBatch(all.list);
    else await window.ShareHub.choose({title:all.info?.name || '分享歌单',cover:all.info?.img || all.info?.cover,songs:all.list});
  }catch(e){if(version===epoch)window.showError?.(e.message);}
  finally{platformBusy.delete(action);if(button)button.disabled=false;}
}
function downloadPlatform(){return platformAction('download');}
function sharePlatform(){return platformAction('share');}
function init(){
  const fav=$('tab-favorites');if(fav)fav.onclick=()=>{favorites();const children=$('favorites-children');if(children){children.style.height='auto';children.classList.remove('hidden');}};
  $('tab-playlists').onclick=e=>{e.preventDefault();show();};
  const main=$('view-search')?.parentElement;
  const view=document.createElement('div');view.id='view-playlists';view.className='hidden media-view';view.innerHTML='<div class="apple-view-intro"><h1>我的歌单</h1><p>收藏、创作与订阅的音乐，每一张都有自己的故事。</p></div><div class="media-actions"><button class="apple-primary" id="personal-new-list">新建歌单</button><button class="apple-secondary" id="personal-sync-lists">立即同步</button></div><div id="personal-playlists-grid" class="personal-playlists-grid"></div>';main?.append(view);
  const hero=document.createElement('section');hero.id='personal-playlist-hero';hero.className='personal-playlist-hero hidden';$('view-search')?.prepend(hero);
  $('personal-new-list').onclick=()=>window.handleCreateList();$('personal-sync-lists').onclick=()=>sync(true);
  window.addEventListener('lx-auth-change',()=>{epoch++;syncing=false;artPending.clear();const grid=$('personal-playlists-grid');if(grid)grid._posterSignature=null;render();hideDetail();setTimeout(()=>sync(),700);});
  setInterval(()=>{if(document.visibilityState==='visible')sync();},30000);render();setTimeout(()=>sync(),1200);
  // Retire controls for server media storage, retain the rest of the settings.
  for(const id of ['setting-enable-server-cache','setting-enable-server-lyric-cache','setting-prefer-server-cache','setting-only-download-mode','setting-server-cache-location','setting-server-cache-naming','server-cache-info','server-music-info']){
    const el=$(id);if(el){el.disabled=true;const row=el.closest('.flex.items-center.justify-between') || el.parentElement;row?.classList.add('retired-server-storage');}
  }
}
window.LibraryHub={show,render,detail,hideDetail,favorites,sync,collectPlatform,downloadPlatform,sharePlatform,lists,adopt:result=>window.__LX_LIBRARY_GETTERS__.adopt(result)};
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();

