(function(){
'use strict';
if(!window.LXNative)return;
const $=id=>document.getElementById(id),esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const paths={home:'<path d="m3 10 9-7 9 7v10H6V10m3 10v-7h6v7"/>',search:'<circle cx="10" cy="10" r="6.5"/><path d="m15 15 5 5"/>',list:'<path d="M4 5h16M4 11h9M4 17h7M19 10v9"/><circle cx="16.5" cy="19" r="2.5"/>',room:'<path d="M4 14v-3a8 8 0 0 1 16 0v3M4 11H2v7h5v-7H4m16 0h2v7h-5v-7h3"/>',mine:'<circle cx="12" cy="8" r="4"/><path d="M4 22v-3a8 8 0 0 1 16 0v3"/>',heart:'<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"/>',download:'<path d="M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5"/>',folder:'<path d="M3 7V4h7l2 3h9v14H3V7Z"/>',settings:'<circle cx="12" cy="12" r="3"/><path d="m10 2-1 3-3 1-3-1-1 4 3 2v3l-3 2 2 4 3-1 3 1 1 3 4-1 1-3 3-1 3 1 1-4-3-2v-3l3-2-2-4-3 1-3-1-1-3-4 1Z"/>',source:'<path d="M8 3v5m8-5v5M5 8h14v4a7 7 0 0 1-14 0V8Zm7 11v4"/>',clock:'<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>',chart:'<path d="M4 21V11h4v10m2 0V3h4v18m2 0v-7h4v7"/>',cloud:'<path d="M6 19a5 5 0 1 1 0-10 7 7 0 0 1 13-2 6 6 0 0 1 0 12H6Z"/>',share:'<path d="M12 16V2m-5 5 5-5 5 5M5 11H3v11h18V11h-2"/>'};
const icon=name=>`<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.65" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name]||paths.list}</svg>`;
const state={page:'home',area:'home',interacted:false,info:window.__LX_NATIVE_BOOTSTRAP__||{},room:{},downloads:[],sources:[],feed:null,feedAt:0,feedLoading:false,player:{},sheet:null};
let originalSwitch,switching=false,container,maxHeight=innerHeight,lastWidth=innerWidth,viewportFrame=0,memberSignature='',mineSignature='',homeLibrarySignature='',downloadSignature='',savedLibrary='';
const request=(op,values)=>window.LXNative.request(op,values);
const perform=action=>Promise.resolve().then(action).catch(error=>window.showError?.(error.message||String(error)));
const own=()=>window.__LX_LIBRARY_GETTERS__?.getData?.()||{defaultList:[],loveList:[],userList:[]};
const libraryLists=()=>[{id:'love',name:'我的收藏',list:own().loveList||[]},{id:'default',name:'默认列表',list:own().defaultList||[]},...(own().userList||[])];
const artwork=song=>{const raw=song?.meta?{...song.meta,...song}:song||{};return raw.img||raw.picUrl||raw.pic||'';};
function image(url,className=''){return url?`<img class="${className}" src="${esc(url)}" alt="" loading="lazy" onerror="this.style.visibility='hidden'">`:'';}
function page(id,html){const node=document.createElement('section');node.id='view-native-'+id;node.className='native-page';node.hidden=true;node.innerHTML=html;container.append(node);return node;}
function hidePages(){for(const node of container.children)if(node.id?.startsWith('view-')){if(node.classList.contains('native-page'))node.hidden=true;else node.classList.add('hidden');}}
function showOwn(id){hidePages();$('view-native-'+id).hidden=false;$('view-native-'+id).classList.remove('hidden');}
function syncNavigation(){
 for(const button of document.querySelectorAll('#mobile-bottom-nav [data-native-page]')){const active=button.dataset.nativePage===state.area;button.classList.toggle('is-active',active);button.setAttribute('aria-current',active?'page':'false');}
 $('mobile-library-tabs')?.setAttribute('hidden','');
}
function closeChat(){if(window.RoomSocial?.state?.open)window.RoomSocial.close();document.body.classList.remove('native-chat-keyboard');}
function go(target){
 state.interacted=true;if(state.page==='room'&&target!=='room')closeChat();closeSheet();
 state.page=target;state.area=['home','search','songlist','leaderboard'].includes(target)?'home':target==='playlists'?'playlists':target==='room'?'room':'mine';
 switching=true;
 try{
  if(['home','mine','room','downloads','sources'].includes(target)){
   originalSwitch('search');showOwn(target);
   if(target==='home'){renderHomeLibrary();void loadFeed();}
   if(target==='mine')renderMine();
   if(target==='room')renderRoom();
   if(target==='downloads')void loadDownloads();
   if(target==='sources')void loadSources();
  }else{
   for(const node of container.querySelectorAll('.native-page'))node.hidden=true;
   if(target==='favorites')window.LibraryHub.favorites();
   else if(target==='playlists')window.LibraryHub.show();
   else originalSwitch(target);
  }
 }finally{switching=false;syncNavigation();window.MobileShell?.update();}
}
function viewport(){
 cancelAnimationFrame(viewportFrame);viewportFrame=requestAnimationFrame(()=>{
  if(innerWidth!==lastWidth){lastWidth=innerWidth;maxHeight=innerHeight;}else maxHeight=Math.max(maxHeight,innerHeight);
  const v=window.visualViewport,height=Math.min(innerHeight,v?.height||innerHeight),editing=!!document.activeElement?.matches('input,textarea,[contenteditable=true]');
  const keyboard=state.page==='room'&&editing&&height<maxHeight-100;
  document.body.classList.toggle('native-chat-keyboard',keyboard);
  document.documentElement.style.setProperty('--native-visible-height',height+'px');
 });
}
function search(value){const query=String(value||'').trim();if(!query)return;go('search');$('search-input').removeAttribute('readonly');$('search-input').value=query;window.doSearch(1);document.activeElement?.blur();}
function play(songs,index){if(!songs[index])return;window.__LX_PLAYER_GETTERS__.setRoomPlaylist(songs,index);return window.playSong(songs[index],index);}
function showSheet(title,content){closeSheet();const wrap=document.createElement('div');wrap.className='native-sheet-wrap';wrap.innerHTML=`<section class="native-sheet" role="dialog" aria-modal="true" aria-label="${esc(title)}"><h2>${esc(title)}<button type="button" class="native-sheet-close" aria-label="关闭">×</button></h2><div class="native-sheet-content"></div></section>`;wrap.querySelector('.native-sheet-content').append(content);wrap.querySelector('.native-sheet-close').onclick=closeSheet;wrap.onclick=event=>{if(event.target===wrap)closeSheet();};document.body.append(wrap);state.sheet=wrap;return wrap;}
function closeSheet(){state.sheet?.remove();state.sheet=null;}
function row(label,action,kind='list',detail=''){const button=document.createElement('button');button.type='button';button.className='native-row';button.innerHTML=icon(kind)+`<span>${esc(label)}</span><small>${esc(detail||'›')}</small>`;button.onclick=()=>perform(action);return button;}
function renderMine(){
 const d=own(),count=state.downloads.filter(x=>x.status==='finished').length,username=state.info.username||localStorage.getItem('lx_sync_user')||'';
 const name=username&&username!=='__device__'?username:'我的音乐';
 const signature=JSON.stringify([name,state.info.server,(d.loveList||[]).length,(d.userList||[]).length,count,state.sources.length]);if(signature===mineSignature)return;mineSignature=signature;
 $('native-person-name').textContent=name;$('native-person-note').textContent=state.info.hasAccount?'已连接账号 · 音乐保存在本机':'本机音乐库 · 无需连接服务器';
 $('native-person-avatar').textContent=Array.from(name)[0];
 const headerAvatar=$('header-avatar-image');if(headerAvatar?.innerHTML)$('native-person-avatar').innerHTML=headerAvatar.innerHTML;
 const grid=$('native-mine-grid');grid.replaceChildren();
 for(const [name,target,kind,detail]of [['我的收藏','favorites','heart',`${(d.loveList||[]).length} 首喜欢的音乐`],['我的歌单','playlists','list',`${(d.userList||[]).length+1} 张私人歌单`],['本地 / 网盘','localmusic','folder','设备文件与云端音乐'],['已下载','downloads','download',`${count} 首 · 可离线播放`],['音源管理','sources','source',`${state.sources.length} 个本地音源`],['设置','settings','settings','外观、播放与同步']]){
  const button=document.createElement('button');button.type='button';button.className='native-mine-card';button.innerHTML=icon(kind)+`<strong>${name}</strong><small>${esc(detail)}</small>`;button.onclick=()=>go(target);grid.append(button);
 }
 const list=$('native-mine-links');list.replaceChildren();list.append(row('账号与同步',()=>{if(!state.info.server)return request('editServer');go('settings');$('btn-mode-local')?.scrollIntoView({block:'center'});},'cloud',state.info.server?'已配置':'可选'),row('睡眠定时',()=>window.openSleepTimerModal(),'clock'),row('更换同步服务器',()=>request('editServer'),'cloud'));
}
function renderHomeLibrary(){
 const d=own(),songs=(d.loveList||[]).slice(0,4),signature=JSON.stringify(songs.map(s=>[s.id,s.name,artwork(s)]));if(signature===homeLibrarySignature)return;homeLibrarySignature=signature;
 const box=$('native-home-favorites');box.replaceChildren();if(!songs.length){box.innerHTML='<p class="native-note">收藏喜欢的歌曲，下次打开就能在这里找到。</p>';return;}
 for(const [index,song]of songs.entries()){const button=document.createElement('button');button.className='native-poster';button.innerHTML=`<span class="native-poster-art">${image(artwork(song))}</span><strong>${esc(song.name)}</strong><small>${esc(song.singer||song.artist||song.meta?.singer||'')}</small>`;button.onclick=()=>perform(()=>play(songs,index));box.append(button);}
}
function renderFeed(){
 const feed=state.feed,hot=$('native-home-hot'),posters=$('native-home-posters');hot.replaceChildren();posters.replaceChildren();
 if(feed?.hot?.length){for(const item of feed.hot.slice(0,10)){const text=typeof item==='string'?item:item.name||item.keyword||item.word||item.searchWord;if(!text)continue;const button=document.createElement('button');button.className='native-chip';button.textContent=text;button.onclick=()=>search(text);hot.append(button);}}
 if(!hot.children.length)hot.innerHTML='<p class="native-note">热搜暂时不可用，可直接搜索歌曲。</p>';
 for(const item of (feed?.lists||[]).slice(0,8)){const button=document.createElement('button');button.className='native-poster';const url=item.img||item.pic||item.cover||item.picUrl;button.innerHTML=`<span class="native-poster-art">${image(url)}</span><strong>${esc(item.name||item.title||'歌单')}</strong><small>${esc(item.author||item.creator?.nickname||'网易云音乐')}</small>`;button.onclick=()=>{go('songlist');window.SongListManager?.openDetail?.(item.id,item.source||'wy');};posters.append(button);}
 if(!posters.children.length)posters.innerHTML='<p class="native-note">推荐歌单暂时不可用，稍后可以刷新。</p>';
 $('native-feed-status').textContent=state.feedAt?'更新于 '+new Date(state.feedAt).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit'}):'推荐与热搜需要联网获取';
}
async function loadFeed(force=false){
 if(state.feedLoading||!force&&state.feed&&Date.now()-state.feedAt<900000)return;
 if(!state.feed){try{const saved=JSON.parse(localStorage.getItem('lx_native_home_feed'));if(saved){state.feed=saved.feed;state.feedAt=saved.at;renderFeed();}}catch{}}
 state.feedLoading=true;$('native-feed-status').textContent='正在更新…';
 const results=await Promise.allSettled([fetch('/api/music/songList/list?source=wy&sortId=new&page=1').then(r=>{if(!r.ok)throw Error('歌单暂不可用');return r.json();}),fetch('/api/music/hotSearch?source=mg').then(r=>{if(!r.ok)throw Error('热搜暂不可用');return r.json();})]);
 const lists=results[0].status==='fulfilled'?results[0].value:null,hot=results[1].status==='fulfilled'?results[1].value:null;
 if(lists||hot){state.feed={lists:Array.isArray(lists)?lists:lists?.list||state.feed?.lists||[],hot:Array.isArray(hot)?hot:hot?.list||hot?.data||state.feed?.hot||[]};state.feedAt=Date.now();try{localStorage.setItem('lx_native_home_feed',JSON.stringify({feed:state.feed,at:state.feedAt}));}catch{}}
 state.feedLoading=false;renderFeed();
}
function memberNode(member){const node=document.createElement('button');node.type='button';node.className='native-member';const name=member.nickname||member.name||'成员',avatar=member.avatar&&window.AccountPanel?.avatarHtml?window.AccountPanel.avatarHtml(member.avatar,name):esc(Array.from(name)[0]);node.innerHTML=`<span class="native-member-avatar">${avatar}</span><small>${esc((member.id===state.room.state?.controllerId?'♛ ':'')+name)}</small>`;node.onclick=showMembers;return node;}
function showMembers(){const box=document.createElement('div');box.className='native-members-grid';for(const member of state.room.participants||[])box.append(memberNode(member));showSheet(`房间成员 · ${(state.room.participants||[]).length} 人`,box);}
function renderRoom(){
 const room=state.room,joined=!!room.binding?.roomId,members=room.participants||[];
 $('native-room-title').textContent=joined?'一起听 · '+room.binding.roomId:'一起听';
 $('native-room-subtitle').textContent=joined?`${members.length} 位成员 · ${room.connected?'已连接':'正在重连…'}`:'同一首歌，同一刻心情';
 $('native-room-welcome').hidden=joined;$('native-room-member-strip').hidden=!joined;$('native-room-tools').hidden=!joined;
 const signature=JSON.stringify([members,room.state?.controllerId]);if(signature!==memberSignature){memberSignature=signature;const strip=$('native-room-member-strip');strip.replaceChildren();for(const member of members)strip.append(memberNode(member));}
 if(joined&&state.page==='room'&&!window.RoomSocial?.state?.open)window.RoomSocial?.open();
 if(!joined&&window.RoomSocial?.state?.open)closeChat();
 $('native-room-connection').hidden=!!state.info.hasAccount;
 $('native-room-connection').textContent=state.info.server?'请先在“我的 → 设置”登录同步账号':'一起听需要同步服务器；其他本地功能可直接使用';
 $('native-room-connect').hidden=!!state.info.hasAccount;
}
async function membership(operation,form){
 if(!state.info.hasAccount){window.showInfo?.('请先连接同步服务器并登录账号');return;}
 const button=form.querySelector('button[type=submit]');button.disabled=true;
 try{await request('roomMembership',{operation,roomId:form.querySelector('[name=roomId]').value.trim(),password:form.querySelector('[name=password]').value});form.hidden=true;await request('roomRefresh');}
 finally{button.disabled=false;}
}
async function leaveRoom(){await request('roomMembership',{operation:'leave'});closeChat();state.room={};renderRoom();}
async function loadDownloads(){const rows=await request('downloads');state.downloads=Array.isArray(rows)?rows:[];renderDownloads();renderMine();}
function renderDownloads(){
 const rows=state.downloads,signature=JSON.stringify(rows.map(x=>[x.id,x.status,x.progress,x.error,x.hasCover,x.hasLyric]));if(signature===downloadSignature)return;downloadSignature=signature;
 const box=$('native-download-list'),existing=new Map([...box.querySelectorAll('[data-download-id]')].map(node=>[node.dataset.downloadId,node]));if(!rows.length)box.replaceChildren();$('native-download-count').textContent=rows.filter(x=>x.status==='finished').length+' 首歌曲已保存在本机';
 if(!rows.length){box.innerHTML='<div class="native-empty">还没有已下载歌曲<br>播放页可保存音乐，也可导入设备文件。<br>同名 .lrc 和封面图片可与音频一起导入。</div>';return;}
 for(const item of rows){const song=item.song||{},rowNode=existing.get(item.id)||document.createElement('article');existing.delete(item.id);const contentSignature=JSON.stringify([item.status,item.error,item.hasCover,item.hasLyric,item.quality,song.name,song.singer]);if(rowNode.dataset.contentSignature===contentSignature){const bar=rowNode.querySelector('.native-download-progress i');if(bar)bar.style.width=Math.max(0,Math.min(100,Number(item.progress)||0))+'%';const label=rowNode.querySelector('small');if(label&&item.status==='downloading')label.textContent='下载中 '+Math.round(item.progress||0)+'%';continue;}rowNode.dataset.contentSignature=contentSignature;rowNode.className='native-download';rowNode.dataset.downloadId=item.id;const ready=item.status==='finished',status=ready?[song.singer||song.artist||'本机音乐',item.quality?.toUpperCase(),item.hasLyric?'歌词':'',item.hasCover?'封面':''].filter(Boolean).join(' · '):item.status==='error'?item.error:item.status==='resolving'?'正在解析音源…':`下载中 ${Math.round(item.progress||0)}%`;
  rowNode.innerHTML=`${image(item.hasCover?'lx-local://cover/'+item.id:artwork(song),'native-download-cover')||'<span class="native-download-cover"></span>'}<button type="button" class="native-download-play"><strong>${esc(song.name||'音乐')}</strong><small>${esc(status)}</small>${!ready&&item.status!=='error'?`<span class="native-download-progress"><i style="width:${Math.max(0,Math.min(100,Number(item.progress)||0))}%"></i></span>`:''}</button><button type="button" class="native-download-more" aria-label="${esc(song.name)}的选项">•••</button>`;
  rowNode.querySelector('.native-download-play').onclick=()=>{if(!ready)return;const songs=state.downloads.filter(x=>x.status==='finished').map(x=>({...x.song,offlineId:x.id,...x.hasCover?{img:'lx-local://cover/'+x.id}:{}}));perform(()=>play(songs,songs.findIndex(s=>s.offlineId===item.id)));};rowNode.querySelector('.native-download-more').onclick=()=>downloadOptions(item);if(!rowNode.parentNode)box.append(rowNode);
 }
 for(const node of existing.values())node.remove();if(rows.length)box.querySelector('.native-empty')?.remove();
}
function downloadOptions(item){const content=document.createElement('div');if(item.status==='finished')content.append(row('播放歌曲',()=>{closeSheet();const songs=state.downloads.filter(x=>x.status==='finished').map(x=>({...x.song,offlineId:x.id,...x.hasCover?{img:'lx-local://cover/'+x.id}:{}}));return play(songs,songs.findIndex(s=>s.offlineId===item.id));},'list'),row('分享歌曲、封面与歌词',()=>request('shareDownload',{downloadId:item.id}),'share'));
 if(item.status==='error')content.append(row('重新下载',async()=>{closeSheet();await request('downloadRemove',{downloadId:item.id});await request('download',{song:item.song,quality:item.quality});await loadDownloads();},'download'));
 if(['downloading','resolving'].includes(item.status))content.append(row('取消下载',async()=>{closeSheet();await request('downloadCancel',{downloadId:item.id});await loadDownloads();},'download'));
 content.append(row('删除本机文件',async()=>{closeSheet();const ok=await window.showSelect('删除已下载歌曲','仅删除这台设备中的下载文件。',{confirmText:'删除'});if(ok){await request('downloadRemove',{downloadId:item.id});await loadDownloads();}},'folder'));showSheet(item.song?.name||'歌曲选项',content);}
async function addDownloads(songs,quality){go('downloads');for(const song of songs){try{await request('download',{song,quality:quality||song.quality||window.settings?.preferredQuality||'flac'});}catch(error){window.showError?.(error.message);}}await loadDownloads();}
async function loadSources(){const rows=await request('sources');state.sources=Array.isArray(rows)?rows:[];renderSources();renderMine();}
function renderSources(){const box=$('native-source-list');box.replaceChildren();if(!state.sources.length){box.innerHTML='<div class="native-empty">导入一次洛雪 .js 音源，之后由手机直接解析。<br>音源文件仅保存在这台设备。<br>尚未导入时，已连接的旧服务器音源可临时继续使用。</div>';return;}for(const item of state.sources){const node=document.createElement('article');node.className='native-source';node.innerHTML=`<strong>${esc(item.name)}</strong><p>${esc([item.version,item.author].filter(Boolean).join(' · '))}</p><p>${esc((item.supportedSources||Object.keys(item.sources||{})).map(x=>({kw:'酷我',kg:'酷狗',wy:'网易',tx:'QQ',mg:'咪咕'})[x]||x).join(' / '))} · ${item.enabled?'已启用':'已停用'}</p><div class="native-page-actions"><button class="native-secondary" data-action="toggle">${item.enabled?'停用':'启用'}</button><button class="native-secondary" data-action="delete">删除</button></div>`;node.querySelector('[data-action=toggle]').onclick=()=>perform(async()=>{await request('sourceEnable',{sourceId:item.id,enabled:!item.enabled});await loadSources();});node.querySelector('[data-action=delete]').onclick=()=>perform(async()=>{const ok=await window.showSelect('删除本地音源',item.name,{confirmText:'删除'});if(ok){await request('sourceRemove',{sourceId:item.id});await loadSources();}});box.append(node);}}
async function importURL(){const url=await window.showInput('导入音源链接','填写洛雪音源 .js 文件的完整网址',{placeholder:'https://…/source.js'});if(!url)return;window.showInfo?.('正在下载并初始化音源…');await request('importSourceURL',{url});await loadSources();window.showSuccess?.('音源已保存在手机');}
async function migrateSources(){const list=await request('serverSources'),rows=Array.isArray(list)?list:list?.sources||[];const content=document.createElement('div');if(!rows.length)content.innerHTML='<p class="native-note">没有读取到服务器音源。可以直接导入原 .js 文件。</p>';for(const item of rows){content.append(row(item.name||'音源',async()=>{if(!item.sourceUrl){window.showInfo?.('此音源由文件上传，请在手机重新选择原 .js 文件');return;}await request('importSourceURL',{url:item.sourceUrl});closeSheet();await loadSources();},'source',item.sourceUrl?'导入':'需原文件'));}showSheet('从服务器迁移音源',content);}
async function saveLibrary(data){const value=data||own();if(!value)return;await window.ListStore?.set(value);const lists=[{id:'love',name:'我的收藏',list:value.loveList||[]},{id:'default',name:'默认列表',list:value.defaultList||[]},...(value.userList||[])];const serialized=JSON.stringify(lists);if(serialized!==savedLibrary){savedLibrary=serialized;await request('library',{lists});}renderMine();renderHomeLibrary();}
async function initLibrary(){
 if(!localStorage.getItem('lx_sync_user')){localStorage.setItem('lx_sync_user','__device__');localStorage.setItem('lx_sync_mode','device');}
 const previousLogin=window.isUserLoggedIn;window.isUserLoggedIn=()=>localStorage.getItem('lx_sync_user')==='__device__'||previousLogin?.();
 const previousPush=window.pushDataChange;window.pushDataChange=async data=>{await saveLibrary(data);if(state.info.hasAccount)return previousPush?.(data);};
 let data=own();if(!data?.username){const cached=await window.ListStore?.get().catch(()=>null);data=cached||{username:localStorage.getItem('lx_sync_user'),defaultList:[],loveList:[],userList:[]};window.__LX_LIBRARY_GETTERS__?.adopt(data);}
 await saveLibrary(data);
}
function attachRoom(){const modal=$('room-chat-modal');if(!modal)return;$('view-native-room').append(modal);const tools=$('native-room-tools');const more=$('room-chat-more'),share=$('room-share-list');if(share)tools.append(share);if(more)tools.append(more);const menu=$('room-chat-more-menu');if(menu){$('view-native-room').append(menu);const members=row('查看房间成员',showMembers,'mine');members.id='native-room-show-members';menu.prepend(members);const exit=document.createElement('button');exit.type='button';exit.className='native-danger';exit.textContent='退出房间';exit.id='native-room-leave';exit.onclick=()=>perform(async()=>{menu.hidden=true;await leaveRoom();});menu.append(exit);}const close=$('room-chat-close');if(close)close.onclick=()=>go('home');}
function init(){
 if(!$('view-search')||window.NativeShell)return;
 const style=document.createElement('style');style.id='lx-native-shell-style';style.textContent=window.__LX_SHELL_CSS__||'';document.head.append(style);document.body.classList.add('native-shell');document.body.classList.toggle('native-rich-effects',localStorage.getItem('lx_native_rich_effects')==='true');
 container=$('view-search').parentElement;originalSwitch=window.switchTab;
 const nav=$('mobile-bottom-nav');nav.innerHTML=[['home','首页'],['playlists','歌单'],['room','一起听'],['mine','我的']].map(([id,title])=>`<button type="button" data-native-page="${id}">${icon(id==='playlists'?'list':id)}<span>${title}</span></button>`).join('');nav.onclick=event=>{const button=event.target.closest('[data-native-page]');if(button)go(button.dataset.nativePage);};
 page('home',`<div class="native-page-inner"><p class="native-eyebrow">LX MUSIC</p><h1 class="native-title">听见今天</h1><form id="native-home-search" class="native-search">${icon('search')}<input id="native-home-query" type="search" placeholder="搜索歌曲、歌手、专辑" enterkeyhint="search" autocomplete="off" aria-label="搜索音乐"></form><div id="native-home-shortcuts" class="native-shortcuts"></div><div class="native-section-head"><h2>热门搜索</h2><button class="native-text-button" id="native-home-refresh">刷新</button></div><div class="native-chips" id="native-home-hot"></div><div class="native-section-head"><h2>我的收藏</h2><button class="native-text-button" id="native-home-all-favorites">查看全部 ›</button></div><div id="native-home-favorites" class="native-posters"></div><div class="native-section-head"><h2>最新歌单</h2><button class="native-text-button" id="native-home-all-playlists">更多歌单 ›</button></div><div id="native-home-posters" class="native-posters"></div><p class="native-note" id="native-feed-status"></p></div>`);
 page('mine',`<div class="native-page-inner"><div class="native-person"><button class="native-person-avatar" id="native-person-avatar" aria-label="个人资料">我</button><div><h1 id="native-person-name">我的音乐</h1><p id="native-person-note">本机音乐库</p></div></div><div id="native-mine-grid" class="native-mine-grid"></div><div class="native-list" id="native-mine-links"></div><p class="native-note">页面和音乐库保存在手机，服务器用于可选同步与一起听。</p></div>`);
 page('downloads',`<div class="native-page-inner"><button class="native-text-button" id="native-download-back">‹ 我的</button><h1 class="native-title">已下载</h1><p class="native-note" id="native-download-count">设备中的音乐</p><div class="native-page-actions"><button class="native-primary" id="native-import-audio">导入设备音乐</button><button class="native-secondary" id="native-download-play-all">播放全部</button></div><div id="native-download-list"></div></div>`);
 page('sources',`<div class="native-page-inner"><button class="native-text-button" id="native-source-back">‹ 我的</button><h1 class="native-title">音源管理</h1><p class="native-note">搜索、歌单和歌词由手机获取。导入洛雪音源后，播放链接也在本机解析；音频仍从原音源下载。</p><div class="native-page-actions"><button class="native-primary" id="native-import-source">导入 .js 文件</button><button class="native-secondary" id="native-import-source-url">导入链接</button><button class="native-secondary" id="native-migrate-sources">从服务器迁移</button></div><label class="native-row"><span>兼容旧服务器音源</span><input type="checkbox" id="native-legacy-source" checked aria-label="兼容旧服务器音源"></label><p class="native-note">尚未导入本地音源时，允许使用当前同步服务器解析播放链接。</p><div id="native-source-list"></div></div>`);
 page('room',`<div class="native-room-header"><div class="native-room-heading"><h1 id="native-room-title">一起听</h1><p id="native-room-subtitle">同一首歌，同一刻心情</p></div><div id="native-room-tools" class="native-room-tools" hidden></div></div><div id="native-room-member-strip" class="native-room-members" hidden></div><div id="native-room-welcome" class="native-room-welcome"><div class="native-room-hero">${icon('room')}<h2>让音乐，近一点。</h2><p>和朋友共享播放进度，边听边聊。<br>创建一个房间，或者加入他们。</p></div><p class="native-note" id="native-room-connection"></p><button class="native-secondary" id="native-room-connect">连接账号</button>${['create','join'].map((type,index)=>`<section class="native-room-fold"><button type="button" data-fold="${type}" aria-expanded="false">${index?'加入房间':'创建房间'}<span>＋</span></button><form id="native-room-${type}-form" hidden><input name="roomId" placeholder="${index?'房间号':'房间号（留空自动生成）'}" autocomplete="off" ${index?'required':''} aria-label="${index?'加入':'创建'}房间号"><input name="password" type="password" placeholder="房间密码（可选）" autocomplete="off" aria-label="房间密码"><button type="submit" class="native-primary">${index?'加入并聊天':'创建并聊天'}</button></form></section>`).join('')}</div>`);
 window.NativeShell={go,syncNavigation,state,addDownloads,loadDownloads,loadSources,saveLibrary,ready:true};
 window.switchTab=function(tab,...args){const result=originalSwitch.call(this,tab,...args);if(!switching){if(!state.interacted&&state.page==='home')showOwn('home');else{for(const node of container.querySelectorAll('.native-page'))node.hidden=true;state.page=tab;state.area=tab==='playlists'?'playlists':['search','songlist','leaderboard'].includes(tab)?'home':'mine';if(tab!=='room')closeChat();}syncNavigation();}return result;};
 $('native-home-search').onsubmit=event=>{event.preventDefault();search($('native-home-query').value);};$('native-home-refresh').onclick=()=>void loadFeed(true);$('native-home-all-favorites').onclick=()=>go('favorites');$('native-home-all-playlists').onclick=()=>go('songlist');
 for(const [label,target,kind]of [['我的收藏','favorites','heart'],['热门榜单','leaderboard','chart'],['已下载','downloads','download']]){const button=document.createElement('button');button.className='native-shortcut';button.innerHTML=icon(kind)+`<strong>${label}</strong>`;button.onclick=()=>go(target);$('native-home-shortcuts').append(button);}
 $('native-person-avatar').onclick=()=>{if(state.info.hasAccount)window.AccountPanel?.open();else window.showInfo?.('连接同步账号后可编辑个人资料');};
 for(const id of ['native-download-back','native-source-back'])$(id).onclick=()=>go('mine');$('native-import-audio').onclick=()=>perform(()=>request('importAudio'));$('native-download-play-all').onclick=()=>perform(()=>{const songs=state.downloads.filter(x=>x.status==='finished').map(x=>({...x.song,offlineId:x.id,...x.hasCover?{img:'lx-local://cover/'+x.id}:{}}));return play(songs,0);});
 $('native-legacy-source').onchange=event=>perform(()=>request('sourcePreferences',{legacySourceFallback:event.target.checked}));$('native-import-source').onclick=()=>perform(()=>request('importSource'));$('native-import-source-url').onclick=()=>perform(importURL);$('native-migrate-sources').onclick=()=>perform(migrateSources);
 for(const button of document.querySelectorAll('[data-fold]')){button.onclick=()=>{const form=$('native-room-'+button.dataset.fold+'-form'),show=form.hidden;for(const other of document.querySelectorAll('.native-room-fold form'))other.hidden=true;for(const other of document.querySelectorAll('[data-fold]'))other.setAttribute('aria-expanded','false');form.hidden=!show;button.setAttribute('aria-expanded',String(show));};const form=$('native-room-'+button.dataset.fold+'-form');form.onsubmit=event=>{event.preventDefault();perform(()=>membership(button.dataset.fold,form));};}
 $('native-room-connect').onclick=()=>{if(state.info.server)go('settings');else perform(()=>request('editServer'));};attachRoom();
 const settingsCard=document.createElement('section');settingsCard.className='media-settings-card';settingsCard.id='native-app-settings';settingsCard.innerHTML='<h3>本机播放</h3><p>音源、设备音乐和下载保存在手机。</p><div class="native-page-actions"><button type="button" class="native-secondary" id="native-setting-sources">音源管理</button><button type="button" class="native-secondary" id="native-setting-downloads">已下载</button></div><label class="native-row"><span>增强视觉效果</span><input id="native-rich-effects" type="checkbox" aria-label="增强视觉效果"></label><p class="native-note">关闭时减少背景模糊、歌词发光和持续动画。</p>';$('view-settings').prepend(settingsCard);$('native-setting-sources').onclick=()=>go('sources');$('native-setting-downloads').onclick=()=>go('downloads');$('native-rich-effects').checked=localStorage.getItem('lx_native_rich_effects')==='true';$('native-rich-effects').onchange=event=>{localStorage.setItem('lx_native_rich_effects',String(event.target.checked));document.body.classList.toggle('native-rich-effects',event.target.checked);};
 const oldHeading=$('view-playlists')?.querySelector('h1');if(oldHeading)oldHeading.textContent='歌单';window.openCustomSourceModal=()=>go('sources');
 const previousBatch=window.DeviceLibrary?.downloadBatch;if(window.DeviceLibrary)window.DeviceLibrary.downloadBatch=songs=>perform(()=>addDownloads(songs));
 const manager=window.SystemDownloadManager;if(manager){const previousAdd=manager.addTasks.bind(manager);manager.addTasks=async songs=>{const device=songs.filter(song=>!song.downloadTarget||song.downloadTarget.kind==='device'),cloud=songs.filter(song=>song.downloadTarget&&song.downloadTarget.kind!=='device');if(device.length)await addDownloads(device);if(cloud.length)return previousAdd(cloud);};}
 const more=document.querySelector('[aria-label="播放栏选项"]');if(more)more.onclick=()=>{const song=state.player.song||window.currentPlayingSong,content=document.createElement('div');if(song?.name){content.append(row('保存离线',()=>{closeSheet();return addDownloads([song]);},'download'));if(song.offlineId)content.append(row('分享歌曲、封面与歌词',()=>request('shareDownload',{downloadId:song.offlineId}),'share'));}content.append(row('睡眠定时',()=>{closeSheet();window.openSleepTimerModal();},'clock'),row('音源管理',()=>{if(!$('view-player-detail').classList.contains('hidden'))window.toggleLyrics();go('sources');},'source'));showSheet('播放选项',content);};
 const toggleLyrics=window.toggleLyrics;window.toggleLyrics=function(...args){const value=toggleLyrics?.apply(this,args);if(!$('view-player-detail')?.classList.contains('hidden')&&typeof currentLyricIndex!=='undefined'&&currentLyricIndex>=0&&!$('audio-player').paused)syncLyricByLineNum(currentLyricIndex);return value;};
 const fetchLyrics=window.fetchLyric;if(fetchLyrics)window.fetchLyric=async function(song,...args){if(!song.offlineId)return fetchLyrics.call(this,song,...args);try{const lyric=await request('downloadAssets',{downloadId:song.offlineId});currentRawLrc=lyric.lyric||lyric.lrc||'';currentRawTlrc=lyric.tlyric||'';currentRawRlrc=lyric.rlyric||'';currentRawKlrc=lyric.klyric||lyric.lxlyric||'';currentLyricIndex=-1;initLyricPlayer();applyLyricUpdate();if(!currentRawLrc)renderLyric([],'本机未保存歌词，可在下载前获取歌词后重新保存');}catch(error){window.showInfo?.(error.message);}};
 window.addEventListener('lx-native-playback',event=>{state.player=event.detail||{};document.body.classList.toggle('native-has-player',!!state.player.song?.name);if(state.player.playing&&typeof wordAnimationId!=='undefined'&&!wordAnimationId&&typeof currentLyricIndex!=='undefined'&&currentLyricIndex>=0&&!$('view-player-detail')?.classList.contains('hidden'))syncLyricByLineNum(currentLyricIndex);});
 window.addEventListener('lx-native-room',event=>{state.room=event.detail||{};if(state.page==='room')renderRoom();});
 window.addEventListener('lx-native-download',event=>{const update=event.detail,id=update.id,index=state.downloads.findIndex(x=>x.id===id);if(update.deleted)state.downloads=state.downloads.filter(x=>x.id!==id);else if(index>=0)state.downloads[index]={...state.downloads[index],...update};else state.downloads.unshift(update);if(state.page==='downloads')renderDownloads();if(state.page==='mine')renderMine();});
 window.addEventListener('lx-native-sources',()=>{void loadSources();void loadDownloads();});document.addEventListener('visibilitychange',()=>{if(!document.hidden&&['downloads','mine'].includes(state.page))void loadDownloads();});window.addEventListener('lx-auth-change',()=>{mineSignature='';perform(async()=>{state.info=await request('appInfo');renderMine();renderRoom();});});
 window.addEventListener('resize',viewport,{passive:true});window.visualViewport?.addEventListener('resize',viewport,{passive:true});document.addEventListener('focusin',viewport);document.addEventListener('focusout',()=>setTimeout(viewport,150));
 perform(async()=>{state.info=await request('appInfo')||{};$('native-legacy-source').checked=state.info.legacySourceFallback!==false;await initLibrary();renderMine();renderRoom();});void loadDownloads();void loadSources();
 showOwn('home');renderHomeLibrary();renderFeed();void loadFeed();syncNavigation();viewport();
}
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(init,0),{once:true});else setTimeout(init,0);
})();
