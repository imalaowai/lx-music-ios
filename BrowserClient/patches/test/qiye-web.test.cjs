'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../public/music/js');
const AUDIO=Buffer.concat([Buffer.from('ID3'),Buffer.alloc(64)]),COVER=Buffer.from([255,216,255,224,0,16]);
function setupOffline(customFetch){
 const rows=new Map(),events=new EventTarget(),saved=new Map([['lx_sync_user','alice']]);let n=0,queue,played;
 const indexedDB={open(){const request={};queueMicrotask(()=>{request.result={createObjectStore(){},transaction(){const tx={};tx.objectStore=()=>Object.fromEntries(['get','getAll','put','delete'].map(method=>[method,value=>{const op={};queueMicrotask(()=>{if(method==='put')rows.set(value.key,structuredClone(value));if(method==='delete')rows.delete(value);op.result=method==='get'?structuredClone(rows.get(value)):method==='getAll'?structuredClone([...rows.values()]):undefined;op.onsuccess?.();queueMicrotask(()=>tx.oncomplete?.());});return op;}]));return tx;}};request.onupgradeneeded?.();request.onsuccess?.();});return request;}};
 const window=Object.assign(events,{indexedDB,DeviceLibrary:{identity:()=>saved.get('lx_sync_user'),uuid:()=>String(++n)},getUserAuthHeaders:()=>({'x-user-name':saved.get('lx_sync_user')}),__LX_PLAYER_GETTERS__:{setRoomPlaylist:(songs,index)=>queue={songs,index}},playSong:(song,index)=>{played={song,index};}});
 const context={window,indexedDB,localStorage:{getItem:k=>saved.get(k)||null},Blob,File,URL,TextDecoder,Uint8Array,CustomEvent,Response,AbortController,DOMException,Map,console,setTimeout,fetch:customFetch||(async(_url,options)=>{const part=JSON.parse(options.body).parts[0];return new Response(part==='song'?AUDIO:part==='lyrics'?'[00:00.00]离线歌词':COVER,{headers:{'content-type':part==='song'?'audio/mpeg':part==='lyrics'?'text/plain':'image/jpeg'}});}),navigator:{}};
 vm.runInNewContext(fs.readFileSync(root+'/browser_downloads.js','utf8'),context);
 vm.runInNewContext(fs.readFileSync(root+'/qiye_offline.js','utf8'),context);
 return {api:window.QiyeOffline,rows,saved,window,playback:()=>({queue,played})};
}
async function waitFor(check){for(let i=0;i<150;i++){const value=await check();if(value)return value;await new Promise(r=>setTimeout(r,5));}assert.fail('offline operation did not finish');}
test('Imported audio retains sidecars, plays a real Blob URL through the browser player, and remains account scoped',async()=>{
 const h=setupOffline(),audio=new File([AUDIO],'听海.mp3',{type:'audio/mpeg'}),lrc=new File(['[00:00.00]海风'],'听海.lrc'),cover=new File(['cover'],'听海.jpg',{type:'image/jpeg'});
 await h.api.importFiles([audio,lrc,cover]);const [record]=await h.api.list();assert.equal(record.hasCover,true);assert.equal(record.hasLyric,true);assert.match(record.song.url,/^blob:/);assert.match(record.song.img,/^blob:/);
 await h.api.play(record.id);assert.equal(h.playback().played.song.url,record.song.url);assert.equal(h.playback().queue.songs.length,1);assert.equal(h.playback().played.song.isLocal,true);assert.equal((await h.api.assets(record.id)).lyric,'[00:00.00]海风');
 h.saved.set('lx_sync_user','bob');h.window.dispatchEvent(new Event('lx-auth-change'));assert.equal((await h.api.list()).length,0);await assert.rejects(()=>h.api.play(record.id),/当前账号/);h.saved.set('lx_sync_user','alice');assert.equal((await h.api.list()).length,1);
});
test('Download stores media bytes, lyrics and cover; refresh exposes playable files and removal clears them',async()=>{
 const h=setupOffline(),r=await h.api.add({id:'online',name:'远方',source:'wy'},'128k',['song','lyrics','cover']);
 const row=await waitFor(async()=>{const [row]=await h.api.list();return row?.status==='finished'&&row;});assert.equal(row.id,r.id);assert.equal(row.hasLyric,true);assert.equal(row.hasCover,true);assert.equal((await h.api.assets(r.id)).lyric,'[00:00.00]离线歌词');
 await h.api.play(r.id);assert.match(h.playback().played.song.url,/^blob:/);assert.equal((await h.api.add(row.song,'original',['song'])).id,r.id);assert.equal((await h.api.list()).length,1);await h.api.remove(r.id);assert.equal((await h.api.list()).length,0);
});
test('Cancelling a queued download persists cancellation and never requests that track',async()=>{
 const requested=[],pending=[];const h=setupOffline((_url,options)=>{requested.push(JSON.parse(options.body).song.id);return new Promise((resolve,reject)=>{pending.push(resolve);options.signal.addEventListener('abort',()=>reject(new DOMException('cancelled','AbortError')),{once:true});});});
 const ids=[];for(const id of ['one','two','three'])ids.push((await h.api.add({id,name:id,source:'wy'},'128k',['song'])).id);
 await h.api.cancel(ids[2]);const third=(await h.api.list()).find(r=>r.id===ids[2]);assert.equal(third.status,'error');assert.match(third.error,/取消/);assert.deepEqual(requested,['one','two']);
 for(const resolve of pending)resolve(new Response(AUDIO,{headers:{'Content-Type':'audio/mpeg'}}));await waitFor(async()=> (await h.api.list()).filter(r=>r.status==='finished').length===2);assert.deepEqual(requested,['one','two']);
});
test('Browser room membership uses existing account API and keeps native browser media methods unchanged',async()=>{
 const events=new EventTarget(),saved=new Map([['lx_sync_user','alice']]),calls=[],audioPlay=function originalBrowserPlay(){},mediaSession={setActionHandler(){}};let binding=null,refresh=0;
 const document={documentElement:{dataset:{}},getElementById:()=>null},window=Object.assign(events,{getUserAuthHeaders:()=>({'x-user-token':'fixture-token'}),HTMLMediaElement:{prototype:{play:audioPlay}},navigator:{mediaSession},ListenRoom:{getBinding:()=>binding,debugState:()=>({participants:[],state:{}}),isConnected:()=>true,refreshBinding:async()=>{refresh++;binding={roomId:'test_room'};},disconnect:()=>{binding=null;}}});
 vm.runInNewContext(fs.readFileSync(root+'/qiye_browser.js','utf8'),{window,document,localStorage:{getItem:k=>saved.get(k)||null,setItem:(k,v)=>saved.set(k,v)},location:{origin:'https://fixture.test'},CustomEvent,URL,console,fetch:async(route,options)=>{calls.push({route,options});return new Response('{"success":true}');}});
 await window.LXNative.request('roomMembership',{operation:'create',roomId:' test_room ',password:''});assert.equal(calls[0].route,'/api/room/create');assert.equal(JSON.parse(calls[0].options.body).roomId,'test_room');assert.equal(calls[0].options.headers['x-user-token'],'fixture-token');assert.equal(refresh,1);assert.equal(window.HTMLMediaElement.prototype.play,audioPlay);assert.equal(window.navigator.mediaSession,mediaSession);
 await window.LXNative.request('roomMembership',{operation:'leave'});assert.equal(binding,null);assert.equal(saved.get('lx_sync_user'),'alice');
});

test('A failed download can be removed and retried using its displayed song metadata',async()=>{
 let attempt=0;const h=setupOffline(async()=>++attempt===1?new Response('{"error":"temporary failure"}',{status:502,headers:{'Content-Type':'application/json'}}):new Response(AUDIO,{headers:{'Content-Type':'audio/mpeg'}}));
 const first=await h.api.add({id:'retry',name:'再听一次',source:'wy'},'128k',['song']);const failed=await waitFor(async()=>{const [r]=await h.api.list();return r?.status==='error'&&r;});await h.api.remove(first.id);const second=await h.api.add(failed.song,'128k',['song']);assert.notEqual(second.id,first.id);await waitFor(async()=>{const [r]=await h.api.list();return r?.status==='finished';});await h.api.play(second.id);assert.match(h.playback().played.song.url,/^blob:/);
});

test('Legacy fake offline audio is marked invalid before playback or export',async()=>{const h=setupOffline();await h.api.importFiles([new File(['{"error":"expired"}'],'旧歌曲.mp3',{type:'audio/mpeg'})]);const [r]=await h.api.list();await assert.rejects(()=>h.api.play(r.id),/离线文件无效/);const [failed]=await h.api.list();assert.equal(failed.status,'error');await assert.rejects(()=>h.api.bundle(r.id,['song']),/错误内容/);});
