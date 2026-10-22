
(function () {
  'use strict';
  const $=id=>document.getElementById(id),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const state={roomId:'',revision:-1,messages:[],selected:new Set(),unread:new Set(),members:[],epoch:0,open:false,multi:false,seen:null,limit:60,sending:false};
  let scrollLock;
  const nodeCache=new Map();
  let request=0,returnFocus,memberSignature='',emojiGroup=0,pressTimer,contextId='';
  const binding=()=>window.ListenRoom?.getBinding?.()?.roomId || '',owner=()=>window.DeviceLibrary.identity();
  const markerKey=()=>`lx_room_chat_read:${owner()}:${state.roomId}`;
  const atBottom=()=>{const box=$('room-chat-messages');return !box || box.scrollHeight-box.scrollTop-box.clientHeight<70;};
  function closeContext(){if($('room-chat-context'))$('room-chat-context').hidden=true;contextId='';}
  function hideEmoji(){if($('room-emoji-panel'))$('room-emoji-panel').hidden=true;$('room-chat-emoji')?.setAttribute('aria-expanded','false');}
  function readMarker(){try{const s=JSON.parse(localStorage.getItem(markerKey()));return s && Number.isFinite(s.time)?s:null;}catch{return null;}}
  function markSeen(){
    const time=state.messages.reduce((n,m)=>Math.max(n,m.time),state.seen?.time || 0);
    const ids=state.messages.filter(m=>m.time===time).map(m=>m.id);
    if(!state.unread.size && state.seen?.time===time && ids.length===state.seen.ids.length && ids.every(id=>state.seen.ids.includes(id)))return;
    state.seen={time,ids};
    try{localStorage.setItem(markerKey(),JSON.stringify(state.seen));}catch{}
    state.unread.clear();renderHeader();
  }
  function renderHeader(){
    const button=$('room-chat-btn');if(!button)return;button.hidden=!state.roomId;
    const count=state.unread.size;window.dispatchEvent(new CustomEvent('lx-room-unread',{detail:{count}}));button.classList.toggle('has-unread',count>0);button.setAttribute('aria-label',count?`房间聊天，${count} 条新消息`:'打开房间聊天');button.setAttribute('aria-expanded',String(state.open));
    const badge=$('room-chat-unread');badge.hidden=!count;badge.textContent=count>99?'99+':String(count);
    $('room-chat-title').textContent=state.roomId?`房间 ${state.roomId}`:'房间聊天';$('room-chat-member-count').textContent=`${state.members.length} 位成员 · 一起听，也一起聊`;
    const jump=$('room-chat-jump');jump.hidden=!state.open || !count;jump.textContent=`${count} 条新消息 ↓`;
  }
  function ensureBinding(){
    const roomId=binding();if(roomId===state.roomId)return false;
    state.epoch++;request++;state.roomId=roomId;state.revision=-1;state.messages=[];state.selected.clear();state.unread.clear();state.multi=false;state.seen=roomId?readMarker():null;state.limit=60;state.sending=false;nodeCache.clear();
    if($('room-chat-input'))$('room-chat-input').value='';close();renderMessages(true);renderHeader();return true;
  }
  function adopt(history,roomId){
    if(roomId!==binding() || roomId!==state.roomId || !Number.isFinite(history.revision) || history.revision<=state.revision)return;
    const bottom=atBottom(),initial=state.revision<0;state.revision=history.revision;state.messages=history.messages || [];
    const existing=new Set(state.messages.map(m=>m.id));state.selected=new Set([...state.selected].filter(id=>existing.has(id)));
    if(initial && !state.seen)markSeen();
    else{const seen=state.seen || {time:0,ids:[]};state.unread=new Set(state.messages.filter(m=>m.author.name!==owner() && (m.time>seen.time || m.time===seen.time && !seen.ids.includes(m.id))).map(m=>m.id));}
    renderMessages(bottom);if(state.open && document.visibilityState==='visible' && bottom)markSeen();renderHeader();
  }
  async function refresh(){
    ensureBinding();if(!state.roomId)return;const roomId=state.roomId,epoch=state.epoch,version=++request;
    try{const history=await window.DeviceLibrary.api('/api/room/chat');if(epoch===state.epoch && version===request)adopt(history,roomId);}
    catch(error){if(epoch===state.epoch && version===request)$('room-chat-status').textContent=error.message;}
  }
  function avatar(author){
    const member=state.members.find(m=>m.name===author.name) || author;
    if(member.avatar && window.AccountPanel?.avatarHtml)return window.AccountPanel.avatarHtml(member.avatar,member.nickname || author.name);
    return `<span class="room-chat-avatar-fallback">${esc(Array.from(member.nickname || author.nickname || author.name || '♪')[0])}</span>`;
  }
  async function saveShare(message,mode,button){
    const roomId=state.roomId,epoch=state.epoch;
    try{button.disabled=true;
      if(['play','queue','next'].includes(mode)){const content=await window.DeviceLibrary.api('/api/room/playlist/content',{shareId:message.shareId});if(epoch!==state.epoch || roomId!==binding())return;window.__LX_PLAYER_GETTERS__.enqueue(content.playlist.list,mode);window.showSuccess?.(mode==='play'?'开始播放':mode==='next'?'已加入下一首':'已添加到播放列表');return;}
      let listId;if(mode==='append'){const d=window.__LX_LIBRARY_GETTERS__.getData(),lists=[{id:'love',name:'我的收藏',list:d.loveList},...window.LibraryHub.lists()],labels=lists.map(l=>l.name+' · '+l.id);const selected=await window.showOptions('添加到我的歌单','选择要保存到的歌单',labels);if(!selected)return;listId=lists[labels.indexOf(selected)].id;}
      const result=await window.DeviceLibrary.api('/api/room/playlist/save',{shareId:message.shareId,mode,listId});if(epoch!==state.epoch || roomId!==binding())return;window.LibraryHub.adopt(result.data);window.showSuccess?.(mode==='subscribe'?'已订阅，可在我的歌单查看':mode==='append'?'已添加到所选歌单':'歌单副本已保存');}
    catch(error){if(epoch===state.epoch)window.showError?.(error.message);}finally{button.disabled=false;}
  }
  function renderMessages(bottom=atBottom()){
    const box=$('room-chat-messages');if(!box || (document.documentElement.dataset.nativeApp && !state.open))return;const scroll=box.scrollTop,nodes=[],members=new Map(state.members.map(m=>[m.name,m]));
    if(state.messages.length>state.limit){const b=document.createElement('button');b.className='room-chat-earlier';b.textContent='查看更早的消息';b.onclick=()=>{const height=box.scrollHeight;state.limit+=60;renderMessages(false);box.scrollTop=box.scrollHeight-height+scroll;};nodes.push(b);}
    let lastTime=0;
    for(const m of state.messages.slice(-state.limit)){
      if(m.time-lastTime>300000){const time=document.createElement('p');time.className='room-chat-time';time.textContent=new Date(m.time).toLocaleString('zh-CN',{month:'numeric',day:'numeric',hour:'2-digit',minute:'2-digit'});nodes.push(time);}lastTime=m.time;
      const signature=JSON.stringify([m,members.get(m.author.name),state.multi,state.selected.has(m.id),owner()]),cached=nodeCache.get(m.id);
      if(cached?.signature===signature){nodes.push(cached.row);continue;}
      const own=m.author.name===owner(),row=document.createElement('article'),label=m.author.nickname || m.author.name;row.dataset.messageId=m.id;row.className='room-chat-message'+(own?' is-own':'')+(state.multi?' is-selecting':'')+(state.selected.has(m.id)?' is-selected':'');
      const emojiOnly=m.kind==='text' && window.RoomEmojis?.items.some(e=>e.emoji===m.text.trim());
      row.innerHTML=`${state.multi?`<input type="checkbox" class="room-chat-check" aria-label="选择 ${esc(label)} 的消息" ${state.selected.has(m.id)?'checked':''}>`:''}<span class="room-chat-avatar" title="${esc(label)}">${avatar(m.author)}</span><div class="room-chat-body"><span class="room-chat-author">${esc(label)}</span><div class="room-chat-bubble${emojiOnly?' is-emoji':''}">${['playlist','song'].includes(m.kind)?`<div class="room-share-card"><span class="room-share-cover">${m.playlist.cover?`<img src="${esc(m.playlist.cover)}" alt="" loading="lazy">`:'♫'}</span><div class="room-share-info"><strong>${esc(m.playlist.name)}</strong><p>${m.playlist.count} 首歌曲</p></div><div class="room-share-actions"><button type="button" class="apple-link" data-mode="play">立即播放</button><button type="button" class="apple-link" data-mode="next">下一首播放</button><button type="button" class="apple-link" data-mode="queue">添加播放列表</button><button type="button" class="apple-link" data-mode="append">添加到我的歌单</button><button type="button" class="apple-link" data-mode="copy">保存当前</button>${m.playlist.subscribable!==false && m.kind!=='song'?'<button type="button" class="apple-link" data-mode="subscribe">订阅歌单 ↻</button>':''}</div></div>`:m.kind==='link'?`<div class="room-share-card"><span class="room-share-cover">♫</span><div class="room-share-info"><strong>${esc(m.link.title)}</strong><p>${m.link.count} 首歌曲 · 播放链接</p><a class="apple-link" href="${esc(m.link.path)}" target="_blank" rel="noopener">打开播放页 ↗</a></div></div>`:`<p>${esc(m.text)}</p>`}</div></div>`;
      const toggle=()=>{state.selected.has(m.id)?state.selected.delete(m.id):state.selected.add(m.id);row.classList.toggle('is-selected',state.selected.has(m.id));const check=row.querySelector('input');if(check)check.checked=state.selected.has(m.id);renderSelection();};
      row.querySelector('input')?.addEventListener('change',toggle);row.onclick=e=>{if(state.multi && !e.target.closest('button,input,a'))toggle();};
      row.oncontextmenu=e=>{if(e.target.closest('button'))return;e.preventDefault();showContext(m.id,e.clientX,e.clientY);};
      let startX=0,startY=0;row.addEventListener('pointerdown',e=>{if(e.pointerType!=='touch' || e.target.closest('button,input'))return;startX=e.clientX;startY=e.clientY;clearTimeout(pressTimer);pressTimer=setTimeout(()=>showContext(m.id,startX,startY),550);});
      row.addEventListener('pointermove',e=>{if(Math.abs(e.clientX-startX)+Math.abs(e.clientY-startY)>12)clearTimeout(pressTimer);});for(const type of ['pointerup','pointercancel'])row.addEventListener(type,()=>clearTimeout(pressTimer));
      for(const b of row.querySelectorAll('[data-mode]'))b.onclick=()=>saveShare(m,b.dataset.mode,b);nodeCache.set(m.id,{signature,row});nodes.push(row);
    }
    const live=new Set(state.messages.slice(-state.limit).map(m=>m.id));for(const id of nodeCache.keys())if(!live.has(id))nodeCache.delete(id);
    let cursor=box.firstChild;for(const node of nodes){if(node===cursor)cursor=cursor.nextSibling;else box.insertBefore(node,cursor);}while(cursor){const next=cursor.nextSibling;cursor.remove();cursor=next;}
    if(!state.messages.length)box.innerHTML='<div class="room-chat-empty"><span>♫</span><h3>边听边聊</h3><p>说点什么，或分享一张喜欢的歌单。</p></div>';
    box.scrollTop=bottom?box.scrollHeight:scroll;renderSelection();
  }
  function renderSelection(){
    $('room-chat-selection-bar').hidden=!state.multi;$('room-chat-composer').hidden=state.multi;$('room-chat-selection').textContent=`已选择 ${state.selected.size} 条消息`;$('room-chat-delete-selected').disabled=!state.selected.size;$('room-chat-all').checked=state.messages.length>0 && state.selected.size===state.messages.length;
  }
  function multi(id){closeContext();hideEmoji();state.multi=true;state.selected=new Set(id?[id]:[]);renderMessages(false);$('room-chat-cancel-select').focus({preventScroll:true});}
  function cancelMulti(){state.multi=false;state.selected.clear();renderMessages(false);$('room-chat-input').focus({preventScroll:true});}
  function showContext(id,x,y){
    clearTimeout(pressTimer);hideEmoji();const menu=$('room-chat-context');contextId=id;menu.hidden=false;const rect=menu.getBoundingClientRect();menu.style.left=Math.max(8,Math.min(x,innerWidth-rect.width-8))+'px';const top=window.visualViewport?.offsetTop || 0,height=window.visualViewport?.height || innerHeight;menu.style.top=Math.max(top+8,Math.min(y,top+height-rect.height-8))+'px';menu.querySelector('button').focus({preventScroll:true});
  }
  function update(change){
    if(change.roomId!==binding())return;ensureBinding();if(change.roomId!==state.roomId || change.revision<=state.revision)return;if(change.revision!==state.revision+1){refresh();return;}
    let messages=change.clear?[]:state.messages;if(change.message)messages=[...messages,change.message].slice(-2000);if(change.deletedIds){const ids=new Set(change.deletedIds);messages=messages.filter(m=>!ids.has(m.id));if(ids.has(contextId))closeContext();}adopt({revision:change.revision,messages},change.roomId);
  }
  async function remove(ids,all=false){
    const roomId=state.roomId,epoch=state.epoch;closeContext();try{const result=await window.DeviceLibrary.api('/api/room/chat/delete',{ids,all});if(epoch!==state.epoch || roomId!==binding())return;adopt(result,roomId);if(state.multi)cancelMulti();}catch(error){if(epoch===state.epoch)window.showError?.(error.message);}
  }
  async function send(){
    if(state.sending || !binding())return;const input=$('room-chat-input'),text=input.value.trim();if(!text)return;const roomId=state.roomId,epoch=state.epoch;state.sending=true;$('room-chat-send').disabled=true;
    try{const result=await window.DeviceLibrary.api('/api/room/chat',{text});if(epoch!==state.epoch || roomId!==binding())return;adopt(result,roomId);if(input.value.trim()===text){input.value='';input.style.height='44px';}$('room-chat-status').textContent='';$('room-chat-messages').scrollTop=$('room-chat-messages').scrollHeight;markSeen();}
    catch(error){if(epoch===state.epoch)$('room-chat-status').textContent=error.message;}finally{if(epoch===state.epoch){state.sending=false;$('room-chat-send').disabled=false;if($('room-emoji-panel').hidden&&document.activeElement===input)input.focus({preventScroll:true});}}
  }
  function open(){
    ensureBinding();if(!state.roomId){window.showInfo?.('先加入听歌房间再聊天');window.ListenRoom?.open();return;}returnFocus=document.activeElement;state.open=true;scrollLock?.lock();$('listen-room-modal')?.classList.add('hidden');$('room-chat-modal').hidden=false;document.body.classList.add('room-chat-open');renderMessages(true);markSeen();renderHeader();if(!matchMedia("(max-width:767px), (max-width:1024px) and (pointer:coarse)").matches)$('room-chat-input').focus({preventScroll:true});else if(!document.documentElement.dataset.nativeApp)$('room-chat-close').focus({preventScroll:true});refresh();
  }
  function close(){if(document.activeElement?.closest?.('#room-chat-modal'))document.activeElement.blur();scrollLock?.unlock();document.body.classList.remove('room-chat-open');state.open=false;state.multi=false;state.selected.clear();clearTimeout(pressTimer);closeContext();hideEmoji();if($('room-chat-modal'))$('room-chat-modal').hidden=true;if($('room-chat-btn'))renderHeader();if(!document.documentElement.dataset.nativeApp && returnFocus?.isConnected && !returnFocus.matches('input,textarea,[contenteditable=true]'))returnFocus.focus({preventScroll:true});returnFocus=null;}
  async function share(listId){
    if(!binding()){window.showInfo?.('先加入一个听歌房间再分享');window.ListenRoom?.open();return;}
    try{if(!listId){const lists=[{id:'love',name:'我的收藏',list:window.__LX_LIBRARY_GETTERS__?.getData?.()?.loveList || []},...window.LibraryHub.lists()],labels=lists.map(l=>l.name+' · '+l.list.length+' 首 · '+l.id.slice(-6));const label=await window.showOptions('分享账号歌单','房间成员可以保存副本或订阅更新',labels);if(!label)return;listId=lists[labels.indexOf(label)].id;}ensureBinding();const roomId=state.roomId,epoch=state.epoch;const result=await window.DeviceLibrary.api('/api/room/playlist/share',{listId});if(epoch!==state.epoch || roomId!==binding())return;adopt(result,roomId);open();}
    catch(error){window.showError?.(error.message);}
  }
  async function shareMusic(input){
    if(!binding()){window.showInfo?.('先加入听歌房间再分享');window.ListenRoom?.open();return;}
    if(input.listId && !input.songs?.some(s=>s.deviceKey))return share(input.listId);
    const roomId=binding(),epoch=state.epoch;try{const songs=await window.DeviceLibrary.prepareShare(input.songs,text=>window.showInfo?.(text));if(epoch!==state.epoch || roomId!==binding())return;const result=await window.DeviceLibrary.api('/api/room/playlist/share',{title:input.title,songs});if(epoch!==state.epoch || roomId!==binding())return;adopt(result,roomId);open();}catch(error){window.showError?.(error.message);}
  }
  function renderEmojis(){
    const catalog=window.RoomEmojis;if(!catalog)return;const query=$('room-emoji-search').value.trim(),items=catalog.items.filter(item=>query?item.label.includes(query):item.group===emojiGroup),grid=$('room-emoji-grid');grid.replaceChildren();
    for(const item of items){const button=document.createElement('button');button.type='button';button.className='room-emoji-item';button.textContent=item.emoji;button.title=item.label;button.setAttribute('aria-label',item.label);button.onmousedown=e=>e.preventDefault();button.onclick=()=>{const input=$('room-chat-input'),start=input.selectionStart,end=input.selectionEnd;if(input.value.length-end+start+item.emoji.length>2000){window.showInfo?.('消息最多 2000 个字符');return;}input.setRangeText(item.emoji,start,end,'end');input.dispatchEvent(new Event('input'));input.blur();};grid.append(button);}
    if(!items.length)grid.innerHTML='<p class="room-emoji-empty">没有找到这个表情</p>';$('room-emoji-count').textContent=`200 个常用表情 · ${query?'搜索结果':catalog.groups[emojiGroup].name}`;for(const b of $('room-emoji-tabs').children)b.setAttribute('aria-selected',String(Number(b.dataset.group)===emojiGroup && !query));
  }
  function init(){
    if(!$('room-chat-btn'))return;const modal=document.createElement('div');modal.id='room-chat-modal';modal.hidden=true;
    modal.innerHTML=`<section class="room-chat-window" role="dialog" aria-modal="true" aria-labelledby="room-chat-title"><header class="room-chat-header"><div class="room-chat-heading"><span class="room-chat-heading-icon">♫</span><div><h2 id="room-chat-title">房间聊天</h2><p id="room-chat-member-count"></p></div></div><div class="room-chat-header-actions"><button id="room-share-list" type="button" class="room-chat-tool" title="分享歌单" aria-label="分享歌单">＋<span>歌单</span></button><button id="room-chat-more" type="button" class="room-chat-tool" aria-label="聊天更多操作" aria-expanded="false">•••</button><button id="room-chat-close" type="button" class="room-chat-tool" aria-label="关闭聊天">×</button></div><div id="room-chat-more-menu" hidden><button type="button" id="room-chat-start-select">多选消息</button><button type="button" id="room-chat-clear">清空聊天记录</button></div></header><div class="room-chat-thread"><div id="room-chat-messages" role="log" aria-label="房间聊天消息" aria-live="polite"></div><button type="button" id="room-chat-jump" hidden></button></div><div id="room-chat-selection-bar" hidden><label><input type="checkbox" id="room-chat-all">全选</label><span id="room-chat-selection"></span><button type="button" id="room-chat-cancel-select" class="apple-secondary">取消</button><button type="button" id="room-chat-delete-selected" class="apple-primary">删除所选</button></div><div id="room-chat-composer"><div class="room-chat-toolbar"><button type="button" id="room-chat-emoji" class="room-chat-tool" title="表情" aria-label="打开 200 个常用表情" aria-expanded="false">☺</button><button type="button" id="room-chat-share-inline" class="room-chat-tool" title="分享歌单" aria-label="分享歌单">♫</button><small>右键消息或长按，可删除与多选</small></div><div id="room-emoji-panel" hidden><div class="room-emoji-top"><input id="room-emoji-search" readonly tabindex="-1" placeholder="搜索表情" aria-label="搜索表情"><button type="button" id="room-emoji-close" class="room-chat-tool" aria-label="关闭表情">×</button></div><div id="room-emoji-tabs" role="tablist" aria-label="表情分类"></div><div id="room-emoji-grid" role="group" aria-label="常用表情"></div><p id="room-emoji-count"></p></div><form id="room-chat-form"><textarea id="room-chat-input" maxlength="2000" rows="3" placeholder="和房间成员聊聊…" aria-label="聊天消息"></textarea><div class="room-chat-send-row"><span id="room-chat-status" role="status"></span><small>Enter 发送 · Shift + Enter 换行</small><button type="submit" id="room-chat-send" class="apple-primary">发送</button></div></form></div><div id="room-chat-context" role="menu" aria-label="消息操作" hidden><button type="button" role="menuitem" id="room-chat-copy">复制</button><button type="button" role="menuitem" id="room-chat-delete-one">删除</button><button type="button" role="menuitem" id="room-chat-select-one">多选</button></div></section>`;
    document.body.append(modal);$('room-chat-btn').onclick=open;$('room-chat-close').onclick=close;scrollLock=window.ChatScroll?.install(modal);$('room-share-list').onclick=()=>share();$('room-chat-share-inline').onclick=()=>share();
    const size=()=>{
      if(document.body.classList.contains('native-shell'))return;
      const v=window.visualViewport,keyboard=!!document.activeElement?.matches?.('input,textarea,[contenteditable=true]') && (v?.height || innerHeight)<innerHeight-130;
      const set=(key,value)=>{if(modal.style.getPropertyValue(key)!==value)modal.style.setProperty(key,value);};
      set('--room-chat-viewport',(keyboard?v.height:innerHeight)+'px');set('--room-chat-top',(keyboard?Math.max(0,v.offsetTop):0)+'px');
    };size();window.addEventListener('resize',size);window.visualViewport?.addEventListener('resize',size);window.visualViewport?.addEventListener('scroll',size);
    $('room-chat-more').onclick=()=>{const menu=$('room-chat-more-menu');menu.hidden=!menu.hidden;$('room-chat-more').setAttribute('aria-expanded',String(!menu.hidden));};$('room-chat-start-select').onclick=()=>{multi();$('room-chat-more-menu').hidden=true;};
    $('room-chat-clear').onclick=async()=>{const roomId=state.roomId,epoch=state.epoch;$('room-chat-more-menu').hidden=true;const ok=await window.showSelect('清空房间聊天','所有成员都将无法查看这些记录。',{confirmText:'清空聊天'});if(ok && roomId===binding() && epoch===state.epoch)remove([],true);};
    $('room-chat-all').onchange=e=>{state.selected=new Set(e.target.checked?state.messages.map(m=>m.id):[]);renderMessages(false);};$('room-chat-delete-selected').onclick=()=>state.selected.size && remove([...state.selected]);$('room-chat-cancel-select').onclick=cancelMulti;
    $('room-chat-delete-one').onclick=()=>contextId && remove([contextId]);$('room-chat-select-one').onclick=()=>multi(contextId);
    $('room-chat-copy').onclick=async()=>{const m=state.messages.find(m=>m.id===contextId);closeContext();if(!m)return;try{if(!navigator.clipboard)throw new Error('当前浏览器无法复制，请选中文字复制');await navigator.clipboard.writeText(m.text || m.playlist?.name || location.origin+m.link.path);window.showSuccess?.('已复制');}catch(error){window.showInfo?.(error.message);}};
    $('room-chat-input').addEventListener('pointerdown',event=>{if(document.documentElement.dataset.nativeApp && document.activeElement!==event.currentTarget && event.isPrimary!==false){event.preventDefault();hideEmoji();event.currentTarget.focus({preventScroll:true});}});
    $('room-chat-send').onpointerdown=e=>e.preventDefault();$('room-chat-form').onsubmit=e=>{e.preventDefault();send();};$('room-chat-input').oninput=()=>{if(matchMedia("(max-width:767px), (max-width:1024px) and (pointer:coarse)").matches){const input=$('room-chat-input');input.style.height='44px';input.style.height=Math.min(88,Math.max(44,input.scrollHeight))+'px';}};$('room-chat-input').onkeydown=e=>{if(e.key==='Enter' && !e.shiftKey && !e.isComposing){e.preventDefault();send();}};
    $('room-chat-jump').onclick=()=>{$('room-chat-messages').scrollTop=$('room-chat-messages').scrollHeight;markSeen();};$('room-chat-messages').onscroll=()=>{closeContext();if(state.open && document.visibilityState==='visible' && atBottom())markSeen();};
    for(const [index,group]of (window.RoomEmojis?.groups || []).entries()){const b=document.createElement('button');b.type='button';b.setAttribute('role','tab');b.dataset.group=index;b.textContent=group.icon+' '+group.name;b.onclick=()=>{emojiGroup=index;$('room-emoji-search').value='';renderEmojis();};$('room-emoji-tabs').append(b);}
    $('room-chat-emoji').onclick=()=>{const panel=$('room-emoji-panel');panel.hidden=!panel.hidden;$('room-chat-emoji').setAttribute('aria-expanded',String(!panel.hidden));closeContext();if(panel.hidden)$('room-chat-input').focus({preventScroll:true});if(!panel.hidden){$('room-chat-input').blur();renderEmojis();}};$('room-emoji-close').onclick=()=>{hideEmoji();$('room-chat-input').focus({preventScroll:true});};$('room-emoji-search').oninput=renderEmojis;
    document.addEventListener('pointerdown',e=>{if(!$('room-chat-context').hidden && !e.target.closest('#room-chat-context'))closeContext();if(!e.target.closest('#room-chat-more-menu,#room-chat-more')){$('room-chat-more-menu').hidden=true;$('room-chat-more').setAttribute('aria-expanded','false');}if(e.target.closest('#room-chat-input'))hideEmoji();});
    document.addEventListener('keydown',e=>{if(!state.open || !modal.contains(document.activeElement))return;if(e.key==='Escape'){e.preventDefault();if(!$('room-chat-context').hidden)closeContext();else if(!$('room-emoji-panel').hidden)hideEmoji();else if(state.multi)cancelMulti();return;}if(e.key==='Tab'){const list=[...modal.querySelectorAll('button,input,textarea,[tabindex="0"]')].filter(el=>!el.disabled && el.getClientRects().length),first=list[0],last=list.at(-1);if(e.shiftKey && document.activeElement===first){e.preventDefault();last?.focus();}else if(!e.shiftKey && document.activeElement===last){e.preventDefault();first?.focus();}}});
    document.addEventListener('visibilitychange',()=>{if(document.visibilityState==='visible' && state.open && atBottom())markSeen();});window.addEventListener('lx-room-chat-update',e=>update(e.detail));window.addEventListener('lx-room-chat-history',e=>{ensureBinding();adopt(e.detail,e.detail.roomId);});
    window.addEventListener('lx-room-members-change',e=>{const changed=ensureBinding(),members=e.detail?.participants || [],signature=JSON.stringify(members.map(m=>[m.name,m.nickname,m.avatar]));state.members=members;if(signature!==memberSignature){memberSignature=signature;renderMessages();}renderHeader();if(changed)refresh();});
    const reset=()=>{state.epoch++;state.roomId='';state.revision=-1;state.messages=[];state.selected.clear();state.unread.clear();state.members=[];state.seen=null;close();renderMessages(true);renderHeader();};window.addEventListener('lx-auth-change',reset);window.addEventListener('lx-auth-revoked',reset);
    $('listen-room-btn')?.addEventListener('click',refresh);renderHeader();refresh();
  }
  window.RoomSocial={share,shareMusic,refresh,open,close,state};if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();

