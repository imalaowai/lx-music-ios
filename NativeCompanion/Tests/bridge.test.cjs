'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),{EventEmitter}=require('node:events');
function fixture(){
  const messages=[],listeners={},intervals=[],renders={queue:0,metadata:0};let htmlPlays=0;let context;let ready;const initialized=new Promise(resolve=>ready=resolve);
  class Media extends EventEmitter {constructor(){super();this.id='audio-player';}play(){htmlPlays++;return Promise.resolve();}pause(){}load(){}dispatchEvent(e){this.emit(e.type,e);}addEventListener(n,f){this.on(n,f);}}
  class Storage{constructor(){this.map=new Map();}getItem(k){return this.map.get(k)??null;}setItem(k,v){this.map.set(k,String(v));}removeItem(k){this.map.delete(k);}clear(){this.map.clear();}}
  const storage=new Storage();storage.setItem('lx_sync_user','fixture');storage.setItem('lx_user_token','private-token');
  const audio=new Media(),queue=[{id:'a',name:'A',source:'wy'},{id:'b',name:'B',source:'wy'}];
  const document={documentElement:{dataset:{}},readyState:'loading',visibilityState:'visible',getElementById:id=>id==='audio-player'?audio:null,addEventListener:(n,f)=>listeners[n]=f};
  const window={};window.top=window;window.window=window;
  window.webkit={messageHandlers:{lxNative:{postMessage(value){messages.push(value);queueMicrotask(()=>{window.LXBridge.reply(value.id,true,null);if(value.op==='uiReady')ready();});}}}};
  window.__LX_PLAYER_GETTERS__={getCurrentPlaylist:()=>context.currentPlaylist,getCurrentIndex:()=>context.currentIndex,enqueue(songs){context.currentPlaylist.push(...songs);}};
  window.__LX_LIBRARY_GETTERS__={getData:()=>({loveList:queue,userList:[]})};
  window.removeFromQueue=index=>{context.currentPlaylist.splice(index,1);};window.clearQueue=async()=>{context.currentPlaylist=[];context.currentIndex=-1;};
  window.updatePlayModeUI=()=>{};window.dispatchEvent=()=>{};window.showError=e=>{throw Error(String(e));};
  context={window,document,navigator:{mediaSession:{}},Storage,localStorage:storage,HTMLMediaElement:Media,Event:class{constructor(type){this.type=type;}},CustomEvent:class{constructor(type,value){this.type=type;this.detail=value?.detail;}},setTimeout,clearTimeout,setInterval:f=>intervals.push(f),queueMicrotask,Promise,console,Map,
    settings:{preferredQuality:'flac'},playMode:'list',currentPlaylist:queue,currentIndex:0,currentPlayingSong:null,requestedRoomSong:null,roomAudioSongKey:'',currentQuality:null,playbackProgressReady:false,shouldAutoRecoverPlayback:false,currentLoadingSongId:null,
    updatePlayerInfo(){renders.metadata++;},updatePlayButton(){},setPlayerStatus(){},renderQueue(){renders.queue++;},fetchLyric(){},savePlayHistory(){}};
  vm.runInNewContext(fs.readFileSync(require('node:path').join(__dirname,'../Resources/Bridge.js'),'utf8'),context);
  listeners.DOMContentLoaded();
  context.currentPlaylist=queue.slice();context.currentIndex=0;
  return {window,context,audio,messages,intervals,storage,renders,htmlPlays:()=>htmlPlays,settle:async()=>{await initialized;await new Promise(setImmediate);}};
}
test('Page selections transfer a complete queue; playback never starts HTML audio',async()=>{
  const f=fixture();await f.settle();f.messages.length=0;
  await f.window.playSong(f.context.currentPlaylist[1],1);
  const selected=f.messages.find(x=>x.op==='select');assert.equal(selected.index,1);assert.equal(selected.queue.length,2);assert.equal(selected.quality,'flac');
  await f.window.playNext();await f.window.playPrev();await f.window.togglePlay(true);
  assert.deepEqual(f.messages.filter(x=>['next','previous','pause'].includes(x.op)).map(x=>x.op),['next','previous','pause']);assert.equal(f.htmlPlays(),0);
});
test('Native remote state updates UI without echoing play, pause, seek or room commands',async()=>{
  const f=fixture();await f.settle();f.messages.length=0;
  f.window.LXBridge.state({queue:[{id:'remote',name:'Remote'}],song:{id:'remote',name:'Remote'},index:0,mode:'list',paused:false,position:34,duration:180});
  await f.settle();assert.equal(f.audio.currentTime,34);assert.equal(f.audio.paused,false);assert.equal(f.context.currentPlayingSong.id,'remote');assert.equal(f.messages.length,0);
  f.audio.currentTime=72;await f.settle();assert.equal(f.messages.at(-1).op,'seek');assert.equal(f.messages.at(-1).time,72);
});
test('Login bridge sends an account token and never reads or transfers a password',async()=>{
  const f=fixture();await f.settle();assert.equal(f.messages.find(x=>x.op==='auth').token,'private-token');assert.equal(JSON.stringify(f.messages).includes('password'),false);
  f.storage.removeItem('lx_user_token');await f.settle();assert.equal(f.messages.filter(x=>x.op==='auth').at(-1).token,'');
});
test('Paused web history restore cannot replace the current native queue',async()=>{
  const f=fixture();await f.settle();f.messages.length=0;
  await f.window.playSong({id:'old',name:'Old'},0,null,true);assert.equal(f.messages.length,0);
});

test('Progress-only snapshots retain the queue and avoid repeated metadata and queue renders',async()=>{
  const f=fixture();await f.settle();
  f.window.LXBridge.state({queueRevision:2,queue:[{id:'a',name:'A'},{id:'b',name:'B'}],song:{id:'b',name:'B'},index:1,paused:false,playing:true,position:5,duration:180});
  const before={...f.renders};
  f.window.LXBridge.state({queueRevision:2,index:1,song:{id:'b',name:'B'},paused:false,playing:true,position:6,duration:180});
  assert.equal(f.context.currentPlaylist.length,2);assert.equal(f.audio.currentTime,6);assert.deepEqual(f.renders,before);
});
test('Device volume changes go to the native player without a room command',async()=>{
  const f=fixture();await f.settle();f.messages.length=0;f.audio.volume=0.3;f.audio.muted=true;await f.settle();
  assert.equal(f.messages.at(-1).op,'volume');assert.equal(f.messages.at(-1).muted,true);assert.equal(f.messages.at(-1).volume,0.3);assert.equal(f.messages.some(m=>m.op==='roomMembership'),false);
});

test('Web queue removal and clearing are forwarded to the native queue',async()=>{
  const f=fixture();await f.settle();f.messages.length=0;
  await f.window.removeFromQueue(1);await f.settle();assert.equal(f.messages.find(m=>m.op==='queue').queue.length,1);
  await f.window.clearQueue();await f.settle();assert.equal(f.messages.filter(m=>m.op==='queue').at(-1).queue.length,0);
});
