window.__LX_COMPONENT_RELEASES__=window.__LX_COMPONENT_RELEASES__ || {};
window.__LX_COMPONENT_RELEASES__['js/device_library.js']='2.9.3';
(function () {
  'use strict';
  const $=id=>document.getElementById(id),esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const media=/\.(mp3|flac|wav|m4a|aac|ogg|opus|aiff|alac|wma)$/i;
  function uuid(){if(window.crypto?.randomUUID)return window.crypto.randomUUID();const bytes=new Uint8Array(16);if(window.crypto?.getRandomValues)window.crypto.getRandomValues(bytes);else for(let i=0;i<16;i++)bytes[i]=Math.floor(Math.random()*256);bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;const s=[...bytes].map(x=>x.toString(16).padStart(2,'0')).join('');return s.slice(0,8)+'-'+s.slice(8,12)+'-'+s.slice(12,16)+'-'+s.slice(16,20)+'-'+s.slice(20);}
  const state={owner:null,dirs:[],songs:[],selected:new Set(),multi:false,files:new Map(),urls:new Map(),writeDirs:{},cloud:[],scope:'device',location:null,epoch:0};
  const metadata=new Map();let metadataObserver,metadataQueue=[],metadataActive=0,metadataEpoch=0;
  let dbPromise,scanRevision=0;
  const coverPending=new Map(),coverUrls=new Map();
  function db(){return dbPromise ||= new Promise((resolve,reject)=>{const r=indexedDB.open('lx_device_media',1);r.onupgradeneeded=()=>r.result.createObjectStore('kv');r.onsuccess=()=>resolve(r.result);r.onerror=()=>reject(r.error);});}
  async function kv(key,value,remove=false){const database=await db();return new Promise((resolve,reject)=>{
    const tx=database.transaction('kv',value!==undefined || remove?'readwrite':'readonly'),store=tx.objectStore('kv');
    const r=remove?store.delete(key):value!==undefined?store.put(value,key):store.get(key);let result;r.onsuccess=()=>{result=r.result;};r.onerror=()=>reject(r.error);tx.oncomplete=()=>resolve(result);tx.onerror=()=>reject(tx.error);tx.onabort=()=>reject(tx.error);
  });}
  const identity=()=>localStorage.getItem('lx_sync_user') || window.getUserAuthHeaders?.()['x-user-name'] || '_guest';
  const scoped=key=>identity()+':'+key;
  function ownAuth(){const headers={...window.getUserAuthHeaders?.()};if(headers['x-user-token'] && identity()!=='_guest')headers['x-user-name']=identity();return headers;}
  async function api(route,body,signal){
    const token=window.getUserAuthHeaders?.()['x-user-token'];
    const response=await fetch(route,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json',...ownAuth()},body:body===undefined?undefined:JSON.stringify(body),signal});
    const data=await response.json();
    if(token!==window.getUserAuthHeaders?.()['x-user-token'])throw new Error('账号已切换');
    if(!response.ok || data.success===false)throw new Error(data.message || `请求失败 (${response.status})`);return data;
  }
  function preferences(){try{return JSON.parse(localStorage.getItem(scoped('storage')) || '{}');}catch{return {};}}
  function setPreferences(values){localStorage.setItem(scoped('storage'),JSON.stringify({...preferences(),...values}));applyCachePolicy();}
  function applyCachePolicy(){const enabled=(preferences().cache || 'metadata')!=='off';if(window.settings){Object.assign(window.settings,{enableServerCache:false,enableServerLyricCache:false,preferServerCache:false,enableOnlyDownloadMode:false,enableLyricCache:enabled,enableSongUrlCache:enabled});}}
  async function permission(handle,mode='read',prompt=false){if(!handle)return false;const opts={mode};if(await handle.queryPermission(opts)==='granted')return true;const active=typeof navigator==='undefined' || !navigator.userActivation || navigator.userActivation.isActive;return !!(prompt && active && await handle.requestPermission(opts)==='granted');}
  async function init(event){
    const owner=identity(),keepFiles=state.owner===owner && event?.type!=='lx-auth-revoked';state.owner=owner;
    if(keepFiles){applyCachePolicy();await loadCloud().catch(()=>{});settingsPanel();return;}
    for(const url of coverUrls.values())URL.revokeObjectURL(url);coverUrls.clear();coverPending.clear();
    for(const url of state.urls.values())URL.revokeObjectURL(url);state.urls.clear();
    const epoch=++state.epoch;metadata.clear();metadataEpoch++;metadataQueue=[];metadataObserver?.disconnect();state.dirs=[];state.writeDirs={};state.songs=[];state.selected.clear();state.multi=false;if(!keepFiles)state.files.clear();state.location=null;state.scope='device';
    const dirs=await kv(scoped('dirs')).catch(()=>[]) || [];
    if(epoch!==state.epoch)return;
    state.dirs=dirs;applyCachePolicy();render();
    await scan(false);
    await loadCloud().catch(()=>{});settingsPanel();
  }
  async function scan(refresh=false){
    if(refresh){metadataEpoch++;metadataQueue=[];metadata.clear();}
    const epoch=state.epoch,revision=++scanRevision,owner=identity(),songs=[],dirs=state.dirs;let changed=false;
    const linked=await kv(scoped('links')).catch(()=>({})) || {};
    const append=(dir,relative,locked=false)=>{if(songs.length>=20000)return;const song=makeSong(relative.split('/').pop(),dir.id+':'+relative,dir.name);song.deviceDir=dir.id;song.devicePath=relative;song._requiresPermission=locked;songs.push(song);};
    for(const dir of dirs){
      if(epoch!==state.epoch || revision!==scanRevision || owner!==identity())return;
      try{dir.permissionState=await dir.handle.queryPermission({mode:'read'});}catch{dir.permissionState='prompt';}
      if(epoch!==state.epoch || revision!==scanRevision || owner!==identity())return;
      dir.locked=dir.permissionState!=='granted';dir.accessError='';
      if(dir.locked){for(const relative of dir.catalogue || [])append(dir,relative,true);continue;}
      const start=songs.length,catalogue=[];
      async function walk(handle,parent='',depth=0){if(depth>15 || songs.length>=20000)return;
        for await(const [name,child]of handle.entries()){
          if(epoch!==state.epoch || revision!==scanRevision || owner!==identity())return;
          const relative=parent+name;
          if(child.kind==='directory')await walk(child,relative+'/',depth+1);
          else if(media.test(name)){catalogue.push(relative);append(dir,relative);}
        }
      }
      try{await walk(dir.handle);if(epoch!==state.epoch || revision!==scanRevision || owner!==identity())return;if(JSON.stringify(dir.catalogue)!==JSON.stringify(catalogue)){dir.catalogue=catalogue;changed=true;}}
      catch(error){songs.splice(start);dir.accessError=error.name==='NotFoundError'?'目录已移动或不可用':error.name==='NotAllowedError'?'需要允许访问':'目录暂不可读';dir.locked=error.name==='NotAllowedError';for(const relative of dir.catalogue || [])append(dir,relative,true);}
    }
    if(epoch!==state.epoch || revision!==scanRevision || owner!==identity())return;
    if(changed)await kv(scoped('dirs'),dirs);
    if(epoch!==state.epoch || revision!==scanRevision || owner!==identity())return;
    state.songs=[...songs,...[...state.files].filter(([,file])=>media.test(file.name)).map(([key,file])=>makeSong(file.name,key,'已选择文件'))].map(song=>{applyTags(song,metadata.get(song.deviceKey)?.tags || {});return {...song,...linked[song.deviceKey],_requiresPermission:song._requiresPermission};});render();
  }
  async function restoreDirectory(id,reselect=false){
    const dir=state.dirs.find(item=>item.id===id);if(!dir)return false;
    const owner=identity(),epoch=state.epoch,key=scoped('dirs');
    try{
      // Ask from the actual button click, before IndexedDB or any other await.
      const pending=reselect?window.showDirectoryPicker({id:'lx-music-read',mode:'read'}):dir.handle.requestPermission({mode:'read'});
      const result=await pending;if(epoch!==state.epoch || owner!==identity())return false;
      if(reselect){dir.handle=result;dir.name=result.name;dir.catalogue=[];}else if(result!=='granted'){dir.locked=true;dir.permissionState=result;render();window.showInfo?.('目录仍已保存；允许浏览器读取后即可继续播放。');return false;}
      dir.locked=false;dir.accessError='';dir.permissionState='granted';await kv(key,state.dirs);
      if(epoch!==state.epoch || owner!==identity())return false;await scan(true);return !dir.locked && !dir.accessError;
    }catch(error){if(epoch===state.epoch && owner===identity() && error.name!=='AbortError')window.showError?.(error.name==='SecurityError'?'请直接点击“允许访问”，在浏览器提示中确认。':error.message);return false;}
  }
  // Filename conventions disagree about the artist/title order. Only actual
  // tags or an explicit online association can split them reliably.
  function makeSong(filename,key,folder){return {id:'device_'+key,deviceKey:key,name:filename.replace(/\.[^.]+$/,''),singer:'',source:'device',folder,filename,quality:/\.flac$/i.test(filename)?'flac':'local',isLocal:true};}
  function applyTags(song,tags){
    if(song._metadataLinked)return song;
    const filename=song.filename || song.devicePath?.split('/').pop();
    song.name=String(tags.name || filename?.replace(/\.[^.]+$/,'') || song.name || '未命名音乐');
    song.singer=tags.name?String(tags.singer || ''):'';
    if(tags.albumName)song.albumName=tags.albumName;
    return song;
  }
  function paintSong(row,song){
    row.querySelector('.media-song-copy strong').textContent=song.name;
    row.querySelector('.media-song-copy small').textContent=[song.singer,song.folder].filter(Boolean).join(' · ');
    row.querySelector('.media-song-copy').title=song.name;
    if(song.img){const cover=row.querySelector('.media-song-cover');if(!cover.querySelector('img')){const img=document.createElement('img');img.alt='';img.src=song.img;cover.replaceChildren(img);}}
  }
  function watchMetadata(rows){
    metadataObserver?.disconnect();metadataQueue=[];const version=++metadataEpoch;
    for(const [key,value]of metadata)if(value.pending)metadata.delete(key);
    const enqueue=row=>{const song=row._deviceSong;if(!song || song._requiresPermission || song._metadataLinked || metadata.has(song.deviceKey))return;metadata.set(song.deviceKey,{pending:true,version});metadataQueue.push({row,song,version,owner:identity()});pumpMetadata();};
    if(window.IntersectionObserver){metadataObserver=new IntersectionObserver(entries=>{for(const e of entries)if(e.isIntersecting){metadataObserver.unobserve(e.target);enqueue(e.target);}},{root:$('view-localmusic'),rootMargin:'240px'});for(const row of rows)metadataObserver.observe(row);}
    else rows.slice(0,40).forEach(enqueue);
  }
  function pumpMetadata(){
    while(metadataActive<3 && metadataQueue.length){const item=metadataQueue.shift();metadataActive++;
      (async()=>{const {song,row,version,owner}=item;try{
        if(version!==metadataEpoch || owner!==identity()){if(metadata.get(song.deviceKey)?.version===version)metadata.delete(song.deviceKey);return;}
        const tags=await readTags(await blobFor(song,false));if(!tags.picture)tags.picture=await localCover(song);if(tags.picture){const key='cover:'+song.deviceKey;let url=state.urls.get(key);if(!url){url=URL.createObjectURL(tags.picture);state.urls.set(key,url);}song.img=url;}
        if(version!==metadataEpoch || owner!==identity()){if(metadata.get(song.deviceKey)?.version===version)metadata.delete(song.deviceKey);return;}
        metadata.set(song.deviceKey,{tags});applyTags(song,tags);
        if(row.isConnected)paintSong(row,song);
      }catch{if(version===metadataEpoch && owner===identity())metadata.set(song.deviceKey,{tags:{}});}
      finally{metadataActive--;pumpMetadata();}})();
    }
  }
  async function addDirectory(){
    if(!window.showDirectoryPicker){const input=$('device-dir-input');if('webkitdirectory' in input)input.click();else $('device-file-input').click();return;}
    const owner=identity(),epoch=state.epoch,key=scoped('dirs');
    try {
      const handle=await window.showDirectoryPicker({id:'lx-music-read',mode:'read'});
      if(epoch!==state.epoch || owner!==identity())return;
      for(const dir of state.dirs)if(await dir.handle.isSameEntry(handle)){
        if(epoch!==state.epoch || owner!==identity())return;
        dir.handle=handle;dir.name=handle.name;dir.locked=false;dir.permissionState='granted';await kv(key,state.dirs);await scan(false);window.showSuccess?.('目录连接已恢复');return;
      }
      if(epoch!==state.epoch || owner!==identity())return;
      state.dirs.push({id:uuid(),name:handle.name,handle});await kv(key,state.dirs);await scan(false);
    }catch(error){if(error.name!=='AbortError')window.showError?.(error.message);}
  }
  async function addFiles(files){
    metadataEpoch++;metadataQueue=[];metadata.clear();
    for(const file of files){const relative=file.webkitRelativePath || file.name;if(media.test(file.name) || /\.(lrc|jpg|jpeg|png|webp)$/i.test(file.name))state.files.set('selected:'+relative,file);}
    await scan(false);window.showInfo?.('文件只在当前设备读取，未上传服务器。刷新后需重新选择这些文件。');
  }
  async function blobFor(song,prompt=true){
    if(state.files.has(song.deviceKey))return state.files.get(song.deviceKey);
    const dirs=state.dirs.length?state.dirs:(await kv(scoped('dirs')) || []),dir=dirs.find(x=>x.id===song.deviceDir || song.deviceKey?.startsWith(x.id+':'));
    if(!dir || !await permission(dir.handle,'read',prompt)){
      if(dir && !dir.locked && state.dirs.includes(dir)){dir.locked=true;dir.permissionState='prompt';for(const entry of state.songs)if(entry.deviceDir===dir.id)entry._requiresPermission=true;render();}
      throw Object.assign(new Error('请在本地音乐点击“允许访问”恢复目录读取'),{name:'NotAllowedError',deviceAccessNeeded:true});
    }
    const relative=song.devicePath || song.deviceKey.slice(dir.id.length+1),parts=relative.split('/');let handle=dir.handle;
    for(const part of parts.slice(0,-1))handle=await handle.getDirectoryHandle(part);
    return (await handle.getFileHandle(parts.at(-1))).getFile();
  }
  async function sidecarFile(song,extension){
    const key=song.deviceKey.replace(/\.[^.]+$/,'.'+extension),path=(song.devicePath || '').replace(/\.[^.]+$/,'.'+extension);
    if(state.files.has(key))return state.files.get(key);return blobFor({...song,deviceKey:key,devicePath:path},false);
  }
  async function localCover(song){
    for(const extension of ['jpg','jpeg','png','webp'])try{const blob=await sidecarFile(song,extension);if(blob.size<=8*1024*1024)return new Blob([blob],{type:extension==='jpg' || extension==='jpeg'?'image/jpeg':'image/'+extension});}catch{}
    try{return (await readTags(await blobFor(song,false))).picture || null;}catch{return null;}
  }
  async function localLyric(song){
    if(song.openlist){
      try{const ref={...song.openlist,path:song.openlist.path.replace(/\.[^.]+$/,'.lrc')};const {url}=await resolve({...song,openlist:ref});const res=await fetch(url,{cache:'no-store'});return res.ok?res.text():'';}catch{return '';}
    }
    const lrcKey=song.deviceKey.replace(/\.[^.]+$/,'.lrc');
    if(state.files.has(lrcKey))return state.files.get(lrcKey).text();
    try{return await (await blobFor({...song,deviceKey:lrcKey,devicePath:(song.devicePath || '').replace(/\.[^.]+$/,'.lrc')},false)).text();}catch{const tags=await readTags(await blobFor(song,false));return tags.lyric || '';}
  }
  async function readTags(blob){
    // Read metadata in the device, never upload local audio for inspection.
    const bytes=new Uint8Array(await blob.slice(0,4*1024*1024).arrayBuffer()),view=new DataView(bytes.buffer),out={};
    const ascii=(start,end)=>new TextDecoder('latin1').decode(bytes.subarray(start,end));
    const text=data=>{const encoding=data[0];return new TextDecoder(encoding===1?'utf-16':encoding===2?'utf-16be':encoding===3?'utf-8':'latin1').decode(data.subarray(1)).replace(/\0/g,'').trim();};
    const sync=(start)=>((bytes[start]&127)<<21)|((bytes[start+1]&127)<<14)|((bytes[start+2]&127)<<7)|(bytes[start+3]&127);
    if(ascii(0,3)==='ID3' && [3,4].includes(bytes[3])){
      const version=bytes[3],end=Math.min(bytes.length,10+sync(6));let pos=10;
      if(bytes[5]&64 && pos+4<end)pos+=version===4?sync(pos):4+view.getUint32(pos);
      while(pos+10<=end){const id=ascii(pos,pos+4),length=version===4?sync(pos+4):view.getUint32(pos+4);if(!length || pos+10+length>end)break;
        const value=bytes.subarray(pos+10,pos+10+length);
        if(id==='TIT2')out.name=text(value);else if(id==='TPE1')out.singer=text(value);else if(id==='TALB')out.albumName=text(value);
        else if(id==='APIC'){let i=1;while(i<value.length && value[i])i++;const mime=new TextDecoder().decode(value.subarray(1,i));i+=2;const width=[1,2].includes(value[0])?2:1;while(i+width<value.length && (value[i] || (width===2 && value[i+1])))i+=width;i+=width;if(i<value.length && /^image\/(jpeg|png|webp)$/.test(mime))out.picture=new Blob([value.subarray(i)],{type:mime});}
        else if(id==='USLT'){let i=4,width=[1,2].includes(value[0])?2:1;while(i+width<value.length && (value[i] || (width===2 && value[i+1])))i+=width;i+=width;out.lyric=text(new Uint8Array([value[0],...value.subarray(i)]));}
        pos+=10+length;
      }
    }else if(ascii(0,4)==='fLaC'){
      let pos=4;while(pos+4<bytes.length){const type=bytes[pos]&127,last=bytes[pos]&128,length=(bytes[pos+1]<<16)|(bytes[pos+2]<<8)|bytes[pos+3],start=pos+4,end=start+length;if(end>bytes.length)break;
        if(type===4){let p=start,skip=view.getUint32(p,true);p+=4+skip;if(p+4>end)break;const count=view.getUint32(p,true);p+=4;for(let i=0;i<count && p+4<=end;i++){const n=view.getUint32(p,true);p+=4;if(p+n>end)break;const [key,...value]=new TextDecoder().decode(bytes.subarray(p,p+n)).split('=');const fields={TITLE:'name',ARTIST:'singer',ALBUM:'albumName',LYRICS:'lyric',UNSYNCEDLYRICS:'lyric'};if(fields[key?.toUpperCase()])out[fields[key.toUpperCase()]]=value.join('=');p+=n;}}
        if(type===6 && length>32){try{let p=start+4,n=view.getUint32(p);p+=4;const mime=ascii(p,p+n);p+=n;n=view.getUint32(p);p+=4+n+16;n=view.getUint32(p);p+=4;if(p+n<=end && /^image\/(jpeg|png|webp)$/.test(mime))out.picture=new Blob([bytes.subarray(p,p+n)],{type:mime});}catch{}}
        pos=end;if(last)break;
      }
    }
    return out;
  }
  async function resolve(song){
    if(song.deviceKey){
      const blob=await blobFor(song,false),old=state.urls.get(song.deviceKey);
      const tags=await readTags(blob).catch(()=>({}));if(!tags.picture)tags.picture=await localCover(song);
      if(!song.filename)song.filename=blob.name || song.devicePath?.split('/').pop();
      applyTags(song,tags);
      if(tags.picture){const key='cover:'+song.deviceKey;if(state.urls.has(key))URL.revokeObjectURL(state.urls.get(key));song.img=URL.createObjectURL(tags.picture);state.urls.set(key,song.img);}
      if(old)URL.revokeObjectURL(old);const url=URL.createObjectURL(blob);state.urls.set(song.deviceKey,url);
      return {url,quality:song.quality || 'local',sourceType:'device',songInfo:song};
    }
    if(song.openlist){
      const data=await api('/api/openlist/play',song.openlist);
      const token=window.getUserAuthHeaders?.()['x-user-token'];
      return {url:data.url+'&token='+encodeURIComponent(token || ''),quality:song.quality || 'local',sourceType:'openlist',songInfo:song};
    }
    return null;
  }
  async function loadCloud(){const epoch=state.epoch;const data=await api('/api/openlist/config');if(epoch===state.epoch){state.cloud=data.connections;renderSources();}return data.connections;}
  async function browse(id,dir,page=1,password=''){
    const epoch=++state.epoch;state.scope='cloud';state.selected.clear();
    const connection=state.cloud.find(x=>x.id===id);state.location={id,path:dir,page,password};renderSources();
    const list=$('device-song-list');list.innerHTML='<p class="media-empty">正在读取网盘目录…</p>';
    try {
      const data=await api('/api/openlist/list',{id,path:dir,page,password});if(epoch!==state.epoch)return;
      state.cloudContent=data.content;state.cloudTotal=data.total;
      state.songs=data.content.filter(x=>!x.is_dir && media.test(x.name)).map(x=>{
        const filePath=(dir==='/'?'':dir)+'/'+x.name;
        return {id:'openlist_'+id+'_'+filePath,name:x.name.replace(/\.[^.]+$/,''),singer:connection.name,source:'openlist',isLocal:true,quality:/\.flac$/i.test(x.name)?'flac':'local',img:x.thumb || '',openlist:{id,path:filePath,owner:identity(),password},filename:x.name};
      });render();
    }catch(error){if(epoch===state.epoch)list.innerHTML=`<p class="media-empty">${esc(error.message)}</p><button class="apple-secondary" id="cloud-retry">重新加载</button>`;$('cloud-retry')?.addEventListener('click',()=>browse(id,dir,page,password));}
  }
  function visible(){const query=($('device-search')?.value || '').toLowerCase();let excluded=[];try{excluded=JSON.parse(localStorage.getItem(scoped('removed')) || '[]');}catch{}return state.songs.filter(s=>!excluded.includes(s.id) && (s.name+' '+s.singer+' '+(s.folder || '')).toLowerCase().includes(query));}
  async function associate(song){
    try{const names=['酷狗音乐','网易云音乐','QQ 音乐','酷我音乐','咪咕音乐'],sources=['kg','wy','tx','kw','mg'];
      const platform=await window.showOptions('关联封面与歌词','音频仍从设备目录读取，在线资料用于显示',names);if(!platform)return;
      const query=await window.showInput('搜索在线资料','输入歌名和歌手',{defaultValue:song.name+' '+(song.singer==='本地音乐'?'':song.singer)});if(!query)return;
      const result=await api('/api/music/search?'+new URLSearchParams({source:sources[names.indexOf(platform)],name:query,type:'song',page:1}));
      const candidates=result.list || [];if(!candidates.length)return window.showInfo?.('没有匹配的歌曲');
      const labels=candidates.map((s,i)=>`${s.name} · ${s.singer} · ${s.interval || ''} · ${i+1}`),chosen=await window.showOptions('选择关联歌曲','请确认歌手与版本一致',labels);if(!chosen)return;
      const candidate=window.songMetadata(candidates[labels.indexOf(chosen)]),old={id:song.id,deviceKey:song.deviceKey,deviceDir:song.deviceDir,devicePath:song.devicePath,filename:song.filename,isLocal:true,folder:song.folder};
      Object.assign(song,candidate,old,{_metadataLinked:true});delete song.url;
      const links=await kv(scoped('links')) || {};links[song.deviceKey]={...song};await kv(scoped('links'),links);render();window.showSuccess?.('在线资料已关联');
    }catch(error){window.showError?.(error.message);}
  }
  function renderSources(){
    const el=$('device-sources');if(!el)return;
    el.replaceChildren();
    const add=(label,action,active)=>{const b=document.createElement('button');b.className='media-source'+(active?' selected':'');b.textContent=label;b.onclick=action;el.append(b);};
    add('此设备 · '+state.dirs.length+' 个目录',()=>{state.epoch++;state.scope='device';state.location=null;scan(false);},state.scope==='device');
    for(const c of state.cloud)for(const root of c.roots)add(c.name+' · '+root,()=>browse(c.id,root),state.location?.id===c.id && state.location?.path===root);
  }
  function render(){
    renderSources();const list=$('device-song-list');if(!list)return;
    const songs=visible(),metadataRows=[];list.replaceChildren();
    if(state.scope==='device')for(const dir of state.dirs){const line=document.createElement('div');line.className='media-directory device-directory';line.dataset.directoryId=dir.id;
      line.innerHTML=`<span class="device-directory-name">📁 ${esc(dir.name)}<small>${esc(dir.accessError || (dir.locked?'目录已记住 · 待读取许可':(dir.catalogue?.length || 0)+' 首歌曲'))}</small></span><div class="device-directory-actions">${dir.locked?'<button type="button" class="apple-secondary" data-allow>允许访问</button>':''}${window.showDirectoryPicker && (dir.locked || dir.accessError)?'<button type="button" class="apple-link" data-relocate>重新选择目录</button>':''}<button type="button" class="apple-link" data-remove>移除此目录</button></div>`;
      const allow=line.querySelector('[data-allow]');if(allow)allow.onclick=async()=>{allow.disabled=true;try{await restoreDirectory(dir.id);}finally{allow.disabled=false;}};
      const relocate=line.querySelector('[data-relocate]');if(relocate)relocate.onclick=()=>restoreDirectory(dir.id,true);
      line.querySelector('[data-remove]').onclick=async()=>{state.dirs=state.dirs.filter(x=>x.id!==dir.id);await kv(scoped('dirs'),state.dirs);await scan(false);};list.append(line);
    }
    if(state.scope==='device' && state.dirs.some(dir=>dir.locked)){const note=document.createElement('p');note.className='device-access-note';note.textContent='目录已保存。浏览器收回许可时，点击“允许访问”即可继续，无需重新添加。';list.append(note);}
    if(state.scope==='cloud' && state.location){
      const c=state.cloud.find(x=>x.id===state.location.id),loc=state.location;
      const bar=document.createElement('div');bar.className='media-directory';bar.innerHTML=`<span>${esc(loc.path)}</span><button class="apple-link">上一级</button>`;
      bar.querySelector('button').onclick=()=>{const parent=loc.path.slice(0,loc.path.lastIndexOf('/')) || '/';if(c.roots.some(r=>r==='/' || parent===r || parent.startsWith(r+'/')))browse(c.id,parent,1,loc.password);else window.showInfo?.('已到授权目录');};list.append(bar);
      for(const dir of state.cloudContent || [])if(dir.is_dir){const b=document.createElement('button');b.className='media-directory';b.textContent='📁 '+dir.name;b.onclick=()=>browse(c.id,(loc.path==='/'?'':loc.path)+'/'+dir.name,1,loc.password);list.append(b);}
    }
    for(const song of songs.slice(0,2000)){
      const row=document.createElement('div');row.className='device-song-row song-row'+(state.multi?' is-multi':'');
      row.innerHTML=`${state.multi?`<input type="checkbox" aria-label="选择 ${esc(song.name)}" ${state.selected.has(song.id)?'checked':''}>`:''}<span class="media-song-cover">${song.img?`<img src="${esc(song.img)}" alt="" loading="lazy">`:'♫'}</span><button class="media-song-copy" title="${esc(song.name)}"><strong>${esc(song.name)}</strong><small>${esc([song.singer,song.folder].filter(Boolean).join(' · '))}</small></button><div class="media-song-actions"><button class="apple-link media-download" aria-label="下载 ${esc(song.name)}">↓</button></div>`;
      if(state.multi)row.querySelector('input').onchange=e=>{e.target.checked?state.selected.add(song.id):state.selected.delete(song.id);selection();};
      row.querySelector('.media-song-copy').onclick=async()=>{if(state.multi){state.selected.has(song.id)?state.selected.delete(song.id):state.selected.add(song.id);render();return;}if(song._requiresPermission && !await restoreDirectory(song.deviceDir))return;const queue=visible(),at=queue.findIndex(s=>s.id===song.id);if(at<0)return;window.__LX_PLAYER_GETTERS__?.setRoomPlaylist?.(queue,at);window.playSong(queue[at],at);};
      const actions=row.querySelector('.media-song-actions'),collect=document.createElement('button');collect.className='apple-link media-collect';collect.title='添加到歌单';collect.textContent='＋';collect.onclick=()=>window.openPlaylistAddModalForSongObject?.(song);actions.insertBefore(collect,row.querySelector('.media-download'));
      if(song.deviceKey){const linked=document.createElement('button');linked.className='apple-link media-associate';linked.title='关联封面与歌词';linked.textContent='资料';linked.onclick=()=>associate(song);actions.insertBefore(linked,collect);row._deviceSong=song;metadataRows.push(row);}
      row.querySelector('.media-download').onclick=()=>downloadBatch([song]);const more=document.createElement('button');more.className='apple-link';more.textContent='•••';more.title='歌曲菜单';more.onclick=e=>songMenu(song,e);actions.append(more);row.oncontextmenu=e=>songMenu(song,e);window.MusicContext.bindTouch(row,e=>songMenu(song,e));list.append(row);
    }
    if(!songs.length && !(state.cloudContent || []).some(x=>x.is_dir) && state.scope==='cloud' || !songs.length && state.scope==='device'){
      const p=document.createElement('p');p.className='media-empty';p.textContent=state.scope==='device'?(state.dirs.some(dir=>dir.locked || dir.accessError)?'目录连接已保存，请使用上方按钮恢复访问。':'添加设备目录或选择音乐文件。音频直接在此设备播放。'):'这个目录没有音乐文件。';list.append(p);
    }
    if(state.scope==='cloud' && state.cloudTotal>200){const loc=state.location,nav=document.createElement('div');nav.className='media-actions';for(const [label,page]of [['上一页',loc.page-1],['下一页',loc.page+1]]){const b=document.createElement('button');b.className='apple-secondary';b.textContent=label;b.disabled=page<1 || (page-1)*200>=state.cloudTotal;b.onclick=()=>browse(loc.id,loc.path,page,loc.password);nav.append(b);}list.append(nav);}
    watchMetadata(metadataRows);selection();
  }
  function multi(song){state.multi=true;if(song)state.selected.add(song.id);render();}
  function songMenu(song,e){e.preventDefault();window.MusicContext.open(e,[{label:'多选',action:()=>multi(song)},{label:'添加到歌单',action:()=>window.openPlaylistAddModalForSongObject?.(song)},{label:'移除',action:()=>removeSongs([song])},{label:'下载',action:()=>downloadBatch([song])},{label:'分享',action:()=>window.ShareHub.choose({title:song.name,songs:[song]})},...(song.deviceKey?[{label:'关联封面与歌词',action:()=>associate(song)}]:[])]);}
  function removeSongs(songs){let excluded=[];try{excluded=JSON.parse(localStorage.getItem(scoped('removed')) || '[]');}catch{}for(const song of songs)state.selected.delete(song.id);localStorage.setItem(scoped('removed'),JSON.stringify([...new Set([...excluded,...songs.map(s=>s.id)])]));render();window.showSuccess?.('已从此设备列表移除，原音乐文件保留');}
  function selection(){const tools=$('device-selection-tools');if(tools)tools.hidden=!state.multi;if($('device-multi-toggle'))$('device-multi-toggle').textContent=state.multi?'退出多选':'多选';if($('device-select-all')){const songs=visible();$('device-select-all').checked=!!songs.length && songs.every(s=>state.selected.has(s.id));}if($('device-selection-count'))$('device-selection-count').textContent=state.selected.size+' 首已选择';}
  async function pickWriteDirectory(kind){
    if(!window.showDirectoryPicker){window.showInfo?.('此浏览器不能指定目录。下载使用浏览器保存位置，缓存保存在此设备的浏览器存储。');return;}
    try{const handle=await window.showDirectoryPicker({id:'lx-'+kind,mode:'readwrite'});state.writeDirs[kind]=handle;await kv(scoped(kind+'Dir'),handle);settingsPanel();}catch(e){if(e.name!=='AbortError')window.showError?.(e.message);}
  }
  async function getDirectory(kind){return state.writeDirs[kind] || await kv(scoped(kind+'Dir'));}
  let creationLock=Promise.resolve();
  async function createDownloadFile(dir,filename){
    const previous=creationLock;let release;creationLock=new Promise(resolve=>release=resolve);await previous;
    try{const original=filename.replace(/[\\/\x00-\x1f]/g,'_');let candidate=original;
      for(let i=1;i<=1000;i++){try{await dir.getFileHandle(candidate);candidate=original.replace(/(\.[^.]*)?$/,` (${i+1})$1`);}catch(error){if(error.name!=='NotFoundError')throw error;return dir.getFileHandle(candidate,{create:true});}}
      throw new Error('下载文件重名过多，请更换下载目录');
    }finally{release();}
  }
  async function writeDevice(blob,filename,signal){
    const handle=await getDirectory('download');
    if(handle && await permission(handle,'readwrite',false)){
      const name=filename.replace(/[\\/\x00-\x1f]/g,'_');
      const file=await createDownloadFile(handle,name),writer=await file.createWritable();
      try{if(signal?.aborted)throw new DOMException('已暂停','AbortError');await writer.write(blob);if(signal?.aborted)throw new DOMException('已暂停','AbortError');await writer.close();}catch(e){await writer.abort();throw e;}return;
    }
    const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=filename;document.body.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
  }
  async function prepareShare(songs,progress=()=>{},signal){
    if(!songs.some(s=>s.deviceKey))return songs;
    await loadCloud();if(!state.cloud.length){openCloudSettings();throw new Error('请先配置 OpenList，再创建设备音乐分享');}
    const labels=state.cloud.map(c=>c.name+' · '+c.downloadRoot),chosen=await window.showOptions('设备文件分享','先上传至 OpenList，其他设备才能通过链接播放',labels);if(!chosen)throw new Error('已取消上传');
    const connection=state.cloud[labels.indexOf(chosen)],owner=identity(),result=[];
    for(let i=0;i<songs.length;i++){
      if(signal?.aborted)throw new DOMException('已取消','AbortError');if(identity()!==owner)throw new Error('账号已切换');const song=songs[i];if(!song.deviceKey){result.push(song);continue;}
      progress(`正在上传 ${i+1}/${songs.length}：${song.name}`);
      const blob=await blobFor(song),filename=uuid().slice(0,8)+'-'+(song.filename || blob.name || song.name+'.mp3');
      const response=await fetch('/api/openlist/upload?'+new URLSearchParams({id:connection.id,path:connection.downloadRoot,filename}),{method:'POST',headers:{...ownAuth(),'Content-Type':blob.type || 'application/octet-stream'},body:blob,signal}),data=await response.json();
      if(!response.ok || !data.success)throw new Error(data.message || '上传失败');if(identity()!==owner)throw new Error('账号已切换');
      const next={...song,source:'openlist',openlist:{id:connection.id,path:data.path,owner},filename};for(const key of ['deviceKey','deviceDir','devicePath','url'])delete next[key];if(/^blob:/.test(next.img || ''))delete next.img;result.push(next);
    }
    return result;
  }
  async function downloadBatch(songs){
    if(!songs?.length)return window.showInfo?.('请选择歌曲');
    const browser=window.LXNative?.runtime==='browser';
    const choice=await window.showOptions('下载音乐',`${songs.length} 首歌曲，选择保存位置`,browser?['下载到手机 / 电脑','保存到浏览器离线库','下载到 OpenList']:['下载到此设备','下载到 OpenList']);if(!choice)return false;
    let target={kind:'device'};
    if(choice==='下载到 OpenList'){
      await loadCloud();if(!state.cloud.length){window.showInfo?.('请先添加 OpenList 连接');openCloudSettings();return false;}
      const labels=state.cloud.map(c=>c.name+' · '+c.downloadRoot),selected=await window.showOptions('选择网盘目录','使用各连接设置的下载目录',labels);if(!selected)return false;const c=state.cloud[labels.indexOf(selected)];target={kind:'openlist',id:c.id,path:c.downloadRoot};
    }else if(!browser){const handle=await getDirectory('download');if(handle && !await permission(handle,'readwrite',true))throw new Error('下载目录没有写入权限');
      if(!handle && songs.length>1){target={kind:'device',archive:true,batchId:uuid()};window.showInfo?.('完成后点击下载管理中的“保存 ZIP”，一次保存全部歌曲。');}}
    const selection=await window.DownloadOptions.choose({count:songs.length,probe:()=>songs[0].deviceKey||songs[0].offlineId?Promise.resolve({qualities:[{quality:'original',actualQuality:'original',available:true,format:(songs[0].filename?.split('.').pop() || 'audio').toUpperCase(),extension:songs[0].filename?.split('.').pop() || 'audio'}]}):api('/api/media/options',{song:songs[0]})});if(!selection)return false;
    if(browser && target.kind==='device'){
      if(choice==='保存到浏览器离线库'){
        for(const song of songs)await window.QiyeOffline.add(song,selection.quality,selection.parts);
        window.NativeShell?.go('downloads');window.showInfo?.('已加入离线下载，请保持页面打开');return true;
      }
      await window.BrowserDownloads.songs(songs,selection);return true;
    }
    if(!browser && target.kind==='device' && selection.parts.length>1 && !await getDirectory('download'))target={kind:'device',archive:true,batchId:uuid()};
    await window.SystemDownloadManager.addTasks(songs.map(s=>({...s,quality:selection.quality,downloadParts:selection.parts,downloadTarget:target,isServer:false})));return true;
  }
  async function openCloudSettings(){
    await loadCloud().catch(()=>{});$('openlist-settings-modal')?.remove();
    const modal=document.createElement('div');modal.id='openlist-settings-modal';modal.className='apple-dialog-backdrop';
    modal.innerHTML=`<section class="apple-dialog media-cloud-dialog" role="dialog" aria-modal="true" aria-label="OpenList 连接"><div class="media-dialog-title"><h2>OpenList 连接</h2><button class="apple-link" id="cloud-close">关闭</button></div><p>每个账号的连接独立保存。音乐直接传输至挂载网盘。</p><div id="cloud-connection-list"></div><form id="cloud-form"><input type="hidden" name="id"><label>连接名称<input name="name" required placeholder="我的网盘"></label><label>站点地址<input name="url" type="url" required placeholder="https://openlist.example.com"></label><label>OpenList Token<input name="token" type="password" autocomplete="new-password" placeholder="编辑时留空保留原 Token"></label><label>目录密码（可选）<input name="password" type="password" autocomplete="new-password" placeholder="编辑时留空保留原密码"></label><label>播放目录（每行一个）<textarea name="roots" rows="3">/</textarea></label><label>下载目录<input name="downloadRoot" value="/" required></label><div class="media-actions"><button type="submit" class="apple-primary">保存连接</button><button type="button" id="cloud-new" class="apple-secondary">新建连接</button></div></form><p id="cloud-form-status" role="status"></p></section>`;
    document.body.append(modal);$('cloud-close').onclick=()=>modal.remove();modal.onclick=e=>{if(e.target===modal)modal.remove();};
    const form=$('cloud-form');const draw=()=>{
      $('cloud-connection-list').replaceChildren();
      for(const c of state.cloud){const row=document.createElement('div');row.className='media-directory';row.innerHTML=`<button class="apple-link">${esc(c.name)}</button><button class="apple-link">移除</button>`;
        row.firstChild.onclick=()=>{for(const key of ['id','name','url','downloadRoot'])form.elements[key].value=c[key];form.elements.roots.value=c.roots.join('\n');form.elements.token.value='';form.elements.password.value='';};
        row.lastChild.onclick=async()=>{try{state.cloud=(await api('/api/openlist/config',{id:c.id,remove:true})).connections;draw();renderSources();}catch(e){$('cloud-form-status').textContent=e.message;}};$('cloud-connection-list').append(row);
      }
    };draw();$('cloud-new').onclick=()=>{form.reset();form.elements.id.value='';};
    form.onsubmit=async e=>{e.preventDefault();const body=Object.fromEntries(new FormData(form));body.roots=body.roots.split('\n').map(x=>x.trim()).filter(Boolean);try{state.cloud=(await api('/api/openlist/config',body)).connections;draw();renderSources();$('cloud-form-status').textContent='连接已保存';form.reset();form.elements.id.value='';}catch(error){$('cloud-form-status').textContent=error.message;}};
  }
  async function settingsPanel(){
    const panel=$('device-storage-settings');if(!panel)return;
    const p=preferences(),download=await getDirectory('download').catch(()=>null),cache=await getDirectory('cache').catch(()=>null);
    panel.innerHTML=`<h3>设备缓存与下载</h3><p>这些设置只作用于当前账号在此设备上的浏览器。服务器不保存音乐、歌词和封面缓存。</p><label>缓存策略<select id="device-cache-mode"><option value="off">不缓存</option><option value="metadata">仅缓存封面、歌词与链接</option><option value="audio">缓存音乐与资料</option></select></label><div class="media-actions"><button id="device-download-dir" class="apple-secondary">下载目录：${esc(download?.name || '浏览器默认')}</button><button id="device-cache-dir" class="apple-secondary">缓存目录：${esc(cache?.name || '浏览器存储')}</button><button id="device-cache-clear" class="apple-secondary">清空音乐与资料缓存</button><button id="device-cloud-config" class="apple-secondary">管理 OpenList</button><button id="device-restore-removed" class="apple-secondary">恢复已移除的音乐</button></div><p>支持的浏览器可授权目录；其他浏览器使用文件选择与默认下载位置。选择“不缓存”后不再写入应用媒体缓存。</p>`;
    $('device-restore-removed').onclick=()=>{localStorage.removeItem(scoped('removed'));render();window.showSuccess?.('已恢复列表中的音乐');};
    $('device-cache-mode').value=p.cache || 'metadata';$('device-cache-mode').onchange=e=>setPreferences({cache:e.target.value});
    $('device-download-dir').onclick=()=>pickWriteDirectory('download');$('device-cache-dir').onclick=()=>pickWriteDirectory('cache');$('device-cloud-config').onclick=openCloudSettings;$('device-cache-clear').onclick=async()=>{await clearCache();window.showSuccess?.('设备媒体缓存已清空');};
  }
  async function clearCache(){
    const database=await db(),keys=await new Promise(resolve=>{const r=database.transaction('kv').objectStore('kv').getAllKeys();r.onsuccess=()=>resolve(r.result);});
    const dir=await getDirectory('cache').catch(()=>null);
    for(const key of keys)if(String(key).startsWith(scoped('cache:'))){const entry=await kv(key);if(dir && entry?.handle && /^lx-[a-f\d]{24}\.(mp3|flac|lrc|img|json)$/.test(entry.handle.name))await dir.removeEntry(entry.handle.name).catch(()=>{});await kv(key,undefined,true);}
    for(const key of Object.keys(localStorage))if(key.startsWith('lx_url_v2_'+identity()+'_') || key.startsWith('lx_lyric_v2_'+identity()+'_') || (/^lx_(url|lyric)_/.test(key) && !/^lx_(url|lyric)_v2_/.test(key)))localStorage.removeItem(key);
    if(window.caches)await caches.delete('lx-device-media');
  }
  async function cachedAudio(song,quality){if((preferences().cache || 'metadata')!=='audio')return null;try{const value=await kv(scoped('cache:'+song.id+':'+quality));if(value?.audioPolicyVersion!==2)return null;return value?.blob || (value?.handle?await value.handle.getFile():null);}catch{return null;}}
  async function readMetadata(key){if(preferences().cache==='off')return null;try{const value=await kv(scoped('cache:meta:'+key));return value?.data || (value?.handle?JSON.parse(await (await value.handle.getFile()).text()):null);}catch{return null;}}
  async function storeMetadata(key,data){if(preferences().cache==='off')return;const scope=scoped('cache:meta:'+key),dir=await getDirectory('cache');try{if(dir && await permission(dir,'readwrite',false)){const h=await dir.getFileHandle('lx-'+await digest(scope)+'.json',{create:true}),w=await h.createWritable();await w.write(JSON.stringify(data));await w.close();await kv(scope,{handle:h,time:Date.now(),size:JSON.stringify(data).length});}else await kv(scope,{data,time:Date.now(),size:JSON.stringify(data).length});}catch{}}
  async function cacheAudio(song,quality,url){
    if((preferences().cache || 'metadata')!=='audio' || song.deviceKey || song.openlist)return;
    const scope=scoped('cache:'+song.id+':'+quality),epoch=state.epoch;
    // Reuse the resolved original URL. Optional device caching must not
    // resolve again or stream audio through the application server.
    if(!url)return;
    try{const response=await fetch(url,{cache:'no-store',referrerPolicy:'no-referrer'});if(!response.ok)return;
      if(Number(response.headers.get('content-length'))>100*1024*1024){await response.body.cancel();return;}
      const chunks=[],reader=response.body.getReader();let size=0;while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>100*1024*1024 || epoch!==state.epoch || preferences().cache!=='audio'){await reader.cancel();return;}chunks.push(value);}
      const blob=new Blob(chunks,{type:response.headers.get('content-type') || 'audio/mpeg'});if(epoch!==state.epoch || preferences().cache!=='audio')return;
      const dir=await getDirectory('cache');
      if(dir && await permission(dir,'readwrite',false)){const name='lx-'+await digest(scope)+(String(quality).includes('flac')?'.flac':'.mp3');const h=await dir.getFileHandle(name,{create:true}),w=await h.createWritable();await w.write(blob);await w.close();await kv(scope,{handle:h,size:blob.size,time:Date.now(),audioPolicyVersion:2});}
      else await kv(scope,{blob,size:blob.size,time:Date.now(),audioPolicyVersion:2});
      // Bound browser storage; never remove the user's source/download directories.
      const database=await db(),all=await new Promise(resolve=>{const r=database.transaction('kv').objectStore('kv').getAllKeys();r.onsuccess=()=>resolve(r.result);});
      let total=0;const entries=[];for(const key of all)if(String(key).startsWith(scoped('cache:'))){const entry=await kv(key);total+=entry.size || 0;entries.push([key,entry]);}
      for(const [key,entry]of entries.sort((a,b)=>a[1].time-b[1].time)){if(total<=256*1024*1024)break;await kv(key,undefined,true);total-=entry.size || 0;}
    }catch{}
  }
  function imageSource(src){
    if(typeof src!=='string' || !src.trim())return '/music/assets/logo.svg';
    const value=src.trim();
    try{const base=window.location?.href || (typeof location!=='undefined'?location.href:'http://localhost/'),url=new URL(value,base);if(!['http:','https:','blob:','data:'].includes(url.protocol))return '/music/assets/logo.svg';return new URL(base).protocol==='https:' && url.protocol==='http:'?value.replace(/^http:/i,'https:'):value;}catch{return '/music/assets/logo.svg';}
  }
  async function imageUrl(src){
    src=imageSource(src);
    if(!src || /^(blob:|data:)/.test(src) || src.includes('logo.svg') || preferences().cache==='off')return src;
    const scope=scoped('cache:cover:'+src),owner=identity();if(coverUrls.has(scope))return coverUrls.get(scope);if(coverPending.has(scope))return coverPending.get(scope);
    const pending=(async()=>{try{
      const entry=await kv(scope);let blob=entry?.blob || (entry?.handle?await entry.handle.getFile():null);
      if(!blob){
        const base=window.location?.href || (typeof location!=='undefined'?location.href:'http://localhost/'),sameOrigin=new URL(src,base).origin===new URL(base).origin;
        const abort=new AbortController(),timer=setTimeout(()=>abort.abort(),4000);let response;
        try{response=await fetch(src,{cache:'no-store',referrerPolicy:'no-referrer',signal:abort.signal,headers:sameOrigin?ownAuth():{}});if(!response.ok || !response.headers.get('content-type')?.startsWith('image/'))return src;blob=await response.blob();}finally{clearTimeout(timer);}
        if(blob.size>2*1024*1024 || identity()!==owner || preferences().cache==='off')return src;
        const dir=await getDirectory('cache');
        if(dir && await permission(dir,'readwrite',false)){const handle=await dir.getFileHandle('lx-'+await digest(scope)+'.img',{create:true}),writer=await handle.createWritable();await writer.write(blob);await writer.close();await kv(scope,{handle,size:blob.size,time:Date.now()});}else await kv(scope,{blob,size:blob.size,time:Date.now()});
      }
      if(identity()!==owner || preferences().cache==='off')return src;const url=URL.createObjectURL(blob);coverUrls.set(scope,url);if(coverUrls.size>150){const oldest=coverUrls.keys().next().value;URL.revokeObjectURL(coverUrls.get(oldest));coverUrls.delete(oldest);}return url;
    }catch{return src;}finally{coverPending.delete(scope);}})();coverPending.set(scope,pending);return pending;
  }
  async function digest(text){const value=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(text));return [...new Uint8Array(value)].map(x=>x.toString(16).padStart(2,'0')).join('').slice(0,24);}
  function mount(){
    const view=$('view-localmusic');if(!view)return;
    // The retired server library was a flex column. A long song list shrank
    // source chips to a few pixels and let their text spill outside the border.
    view.classList.remove('flex','flex-col','overflow-hidden');view.classList.add('media-view');
    view.innerHTML=`<div class="apple-view-intro"><h1>本地音乐</h1><p>设备目录与网盘目录，在一个音乐库中播放。</p></div><div class="media-actions"><button class="apple-primary" id="device-add-dir">添加本地目录</button><button class="apple-secondary" id="device-add-files">选择音乐文件</button><button class="apple-secondary" id="device-rescan">刷新目录</button><button class="apple-secondary" id="device-openlist">添加 OpenList</button></div><input type="file" multiple webkitdirectory hidden id="device-dir-input"><input type="file" multiple accept="audio/*,.flac,.lrc,.jpg,.jpeg,.png,.webp" hidden id="device-file-input"><div id="device-sources" class="media-sources"></div><div class="media-actions"><input id="device-search" placeholder="搜索歌曲、歌手或目录"><button class="apple-secondary" id="device-multi-toggle">多选</button><div class="media-actions device-selection-tools" id="device-selection-tools" hidden><label><input type="checkbox" id="device-select-all">全选</label><span id="device-selection-count">0 首已选择</span><button class="apple-secondary" id="device-download-selected">下载所选</button><button class="apple-secondary" id="device-share-selected">分享所选</button><button class="apple-secondary" id="device-remove-selected">移除所选</button></div><button class="apple-secondary" id="device-download-all">下载当前目录</button></div><div id="device-song-list"></div>`;
    $('device-add-dir').onclick=addDirectory;$('device-add-files').onclick=()=>$('device-file-input').click();$('device-rescan').onclick=()=>state.scope==='device'?scan(true):browse(state.location.id,state.location.path,state.location.page,state.location.password);$('device-openlist').onclick=openCloudSettings;
    for(const id of ['device-dir-input','device-file-input'])$(id).onchange=e=>{addFiles(e.target.files);e.target.value='';};$('device-search').oninput=render;$('device-select-all').onchange=e=>{for(const song of visible())e.target.checked?state.selected.add(song.id):state.selected.delete(song.id);render();};
    $('device-multi-toggle').onclick=()=>{state.multi=!state.multi;state.selected.clear();render();};$('device-share-selected').onclick=()=>window.ShareHub.choose({title:'分享音乐',songs:state.songs.filter(s=>state.selected.has(s.id))});$('device-remove-selected').onclick=()=>removeSongs(state.songs.filter(s=>state.selected.has(s.id)));
    $('device-download-selected').onclick=()=>downloadBatch(state.songs.filter(s=>state.selected.has(s.id)));$('device-download-all').onclick=()=>downloadBatch(visible());
    const settings=$('view-settings');if(settings){const card=document.createElement('section');card.id='device-storage-settings';card.className='media-settings-card';settings.prepend(card);}
    // Legacy local/cache panels refer to server paths; replace their navigation.
    window.LocalMusicManager={init:()=>scan(false),loadList:()=>scan(false),refresh:()=>scan(true),fetchData:()=>scan(false),syncRemasterVisibility:()=>{},isPlaylistCollectable:song=>!!(song.deviceKey || song.openlist),toggleCustomDirMode:()=>openCloudSettings(),filterFolder:'device'};
    init();window.addEventListener('lx-auth-change',init);window.addEventListener('lx-auth-revoked',init);
  }
  window.DeviceLibrary={api,ownAuth,identity,uuid,makeSong,applyTags,preferences,setPreferences,applyCachePolicy,resolve,blobFor,sidecarFile,localCover,prepareShare,localLyric,writeDevice,downloadBatch,openCloudSettings,cachedAudio,cacheAudio,imageSource,imageUrl,readTags,readMetadata,storeMetadata,getDirectory,createDownloadFile,settingsPanel,kv,scoped,state,restoreDirectory,addDirectory};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',mount);else mount();
})();
