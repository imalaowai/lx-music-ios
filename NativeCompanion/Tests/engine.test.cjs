const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
function engine(options={}){
 const calls=[],pending=new Map();let sequence=0,context;
 const http=(id,json)=>{const request=JSON.parse(json);calls.push(request);let body={ok:true,url:'https://audio.invalid/song.mp3'};
  if(request.url.includes('search.kuwo.cn'))body={TOTAL:'1',abslist:[{MUSICRID:'MUSIC_123',SONGNAME:'测试歌曲',ARTIST:'歌手',ALBUM:'专辑',DURATION:'180',N_MINFO:'level:standard,bitrate:128,format:mp3,size:3.2Mb',SONGID:'123'}]};
  if(request.url.includes('/playlist/list'))body={code:200,total:1,playlists:[{id:123,name:'真实 SDK 歌单',creator:{nickname:'Creator'},coverImgUrl:'https://image.invalid/cover.jpg',trackCount:10,playCount:100}]};
  if(request.url.includes('/hotcomments/R_SO_4_'))body={code:200,hotComments:[],total:0};
  if(request.url.includes('/song/lyric'))body={code:200,lrc:{lyric:'[00:00.00]本机歌词'},tlyric:{lyric:'[00:00.00]Local lyrics'}};
  if(request.url.includes('/get_res_privilege'))body={error_code:0,data:[{info:{image:'https://image.invalid/kg/{size}/cover.jpg'}}]};
  if(request.url.includes('/getSongPic'))body=options.miguCoverFailure?{returnCode:'999999'}:{returnCode:'000000',largePic:'//image.invalid/mg/cover.jpg'};
  const payload=Buffer.from(JSON.stringify(body));queueMicrotask(()=>context.__nativeReply(id,JSON.stringify({statusCode:200,headers:{'content-type':'application/json'},base64:payload.toString('base64'),text:payload.toString()}),''));
 };
 context={__nativeRandom:n=>crypto.randomBytes(n).toString('base64'),__nativeHTTP:http,__nativeCancel(){},__nativeTimer:(id,delay)=>{const timer=setTimeout(()=>context.__runTimer(id),delay);timer.unref();},__nativeURL:(value,base)=>{const u=new URL(value,base||undefined);return JSON.stringify({origin:u.origin,protocol:u.protocol,host:u.host,hostname:u.hostname,port:u.port,pathname:u.pathname,search:u.search,hash:u.hash});},__nativeComplete:(id,json,error)=>{const item=pending.get(id);if(!item)return;pending.delete(id);clearTimeout(item.timer);error?item.reject(new Error(error)):item.resolve(JSON.parse(json));},console:options.console||console};
 vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,'../generated/LocalEngine.js'),'utf8'),context,{timeout:3000});
 return {context,calls,run:(op,payload={})=>new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>reject(Error('Engine timeout')),4000);pending.set(id,{resolve,reject,timer});context.__engineRun(id,op,JSON.stringify(payload));})};
}
const script=`/** @name Fixture source */
lx.on(lx.EVENT_NAMES.request, async ({source,action,info}) => {
 if(action!=='musicUrl')throw Error('wrong action');
 if(info.type==='flac')throw Error('fixture only has mp3');
 if(lx.utils.crypto.md5('hello')!=='5d41402abc4b2a76b9719d911017c592')throw Error('bad md5');
 const cipher=lx.utils.crypto.aesEncrypt(lx.utils.buffer.from('hello'),'cbc',lx.utils.buffer.from('0123456789abcdef'),lx.utils.buffer.from('0102030405060708'));
 if(lx.utils.buffer.bufToString(cipher,'base64')!=='FL1SM7AKsiwls1Ghnd/yEA==')throw Error('bad AES');
 return await new Promise((resolve,reject)=>lx.request('https://fixture.invalid/resolve',{method:'POST',body:{id:info.musicInfo.songmid,type:info.type}},(error,response,body)=>error?reject(error):resolve(body.url)));
});
lx.send(lx.EVENT_NAMES.inited,{sources:{kw:{name:'KW',type:'music',actions:['musicUrl'],qualitys:['flac','320k','128k']}}});`;
test('Local source import, crypto, callback HTTP and quality fallback work without a server',async()=>{
 const e=engine();const rows=await e.run('import',{id:'fixture',name:'Source',script});assert.equal(rows.length,1);assert.deepEqual(rows[0].supportedSources,['kw']);
 const result=await e.run('resolve',{song:{id:'a',songmid:'123',source:'kw',name:'Song'},quality:'flac',allowFallback:true});assert.equal(result.url,'https://audio.invalid/song.mp3');assert.equal(result.type,'320k');assert.equal(e.calls.length,1);assert.equal(e.calls[0].options.body.type,'320k');assert.equal(e.calls[0].options.body.id,'123');
 await assert.rejects(e.run('resolve',{song:{source:'kw'},quality:'flac',allowFallback:false}),/fixture only/);
 await e.run('enable',{id:'fixture',enabled:false});await assert.rejects(e.run('resolve',{song:{source:'kw'},quality:'128k'}),/导入/);
});
test('A source imported from the server can read its own global LX API and return the web URL format',async()=>{
 const e=engine();
 const serverStyle=(name,platform)=>`/** @name ${name} */
const {on,send,EVENT_NAMES}=window.lx;
if (globalThis.lx!==window.lx || self.lx!==lx || global.lx!==lx || this.lx!==lx) throw Error('inconsistent LX globals');
on(EVENT_NAMES.request,async ({info})=>{
 await Promise.resolve();
 if(globalThis.lx.currentScriptInfo.name!==${JSON.stringify(name)}) throw Error('another source replaced the LX globals');
 if(info.quality!==info.type || info.type!=='192k') throw Error('unsupported requested quality');
 return {data:{url:' //audio.invalid/${platform}.mp3?first=1&amp;second=2 ',quality:info.type}};
});
send(EVENT_NAMES.inited,{sources:{${platform}:{qualitys:['flac','192k']}}});`;
 await Promise.all(['kw','wy'].map(platform=>e.run('import',{id:platform,script:serverStyle(platform,platform)})));
 const results=await Promise.all(['kw','wy'].map(source=>e.run('resolve',{song:{source,songmid:'123'},quality:'flac'})));
 assert.deepEqual(results.map(x=>[x.url,x.type,x.qualityReported,x.sourceId]),[
  ['https://audio.invalid/kw.mp3?first=1&second=2','192k',true,'kw'],
  ['https://audio.invalid/wy.mp3?first=1&second=2','192k',true,'wy'],
 ]);
 assert.equal(e.context.lx,undefined);
});
test('Source playback can use the web sandbox console methods inside an iOS context',async()=>{
 const engineConsole={log(){},warn(){},error(){}};
 const e=engine({console:engineConsole});
 const sourceScript=[
  "lx.on('request',()=>{",
  " console.debug('parsing'); window.console.info('parsing');",
  " globalThis.console.time('resolve'); console.timeEnd('resolve');",
  " return 'https://audio.invalid/track.mp3';",
  "});",
  "lx.send('inited',{sources:{kw:{qualitys:['128k']}}});",
 ].join('\n');
 await e.run('import',{id:'console',script:sourceScript});
 const result=await e.run('resolve',{song:{source:'kw',songmid:'123'},quality:'128k'});
 assert.equal(result.url,'https://audio.invalid/track.mp3');
 assert.equal(engineConsole.debug,undefined);
});
test('URL-only results leave lossless quality unconfirmed and known lossy results are rejected',async()=>{
 const e=engine();
 const sourceScript=[
  "lx.on('request',({info})=>info.musicInfo.songmid==='123'?'https://audio.invalid/track.flac':{url:'https://audio.invalid/track.mp3',type:'320k'});",
  "lx.send('inited',{sources:{kw:{qualitys:['flac']}}});",
 ].join('\n');
 await e.run('import',{id:'quality',script:sourceScript});
 const result=await e.run('resolve',{song:{source:'kw',songmid:'123'},quality:'flac',allowFallback:false});
 assert.equal(result.type,'flac');
 assert.equal(result.qualityReported,false);
 await assert.rejects(e.run('resolve',{song:{source:'kw',songmid:'456'},quality:'flac',allowFallback:false}),/低于请求档位/);
});
test('Provider search is performed from the bundled SDK, not from the sync server',async()=>{
 const e=engine(),songs=await e.run('api',{path:'/api/music/search?source=kw&name=test&page=1'});assert.equal(songs.length,1);assert.equal(songs[0].name,'测试歌曲');assert.equal(String(songs[0].songmid),'123');assert.ok(e.calls.every(x=>new URL(x.url).hostname!=='local.invalid'));assert.ok(e.calls.some(x=>x.url.includes('search.kuwo.cn')));
});
test('Invalid source and unsupported URL schemes fail explicitly',async()=>{
 const e=engine();await assert.rejects(e.run('import',{id:'invalid',script:'lx.send("inited",{sources:{}});'}),/未注册/);
 await e.run('import',{id:'unsafe',script:'lx.on("request",()=>"file:///private/data");lx.send("inited",{sources:{kw:{qualitys:["128k"]}}});'});
 await assert.rejects(e.run('resolve',{song:{source:'kw'},quality:'128k'}),/有效的播放地址/);
});

test('Provider lyric requests return their resolved content for display and offline saving',async()=>{
 const e=engine(),lyric=await e.run('api',{path:'/api/music/lyric?source=wy&songmid=wy_123'});
 assert.equal(lyric.lyric,'[00:00.00]本机歌词');assert.equal(lyric.tlyric,'[00:00.00]Local lyrics');assert.equal(lyric.promise,undefined);
 assert.ok(e.calls.some(call=>call.url.includes('/song/lyric')));
});

test('Provider cover lookup resolves Kugou image URL and its size template',async()=>{
 const e=engine(),result=await e.run('api',{path:'/api/music/pic?source=kg',body:{songInfo:{source:'kg',songmid:'123',hash:'0123456789abcdef0123456789abcdef',albumId:'456'}}});
 assert.equal(result.url,'https://image.invalid/kg/1000/cover.jpg');assert.ok(e.calls.some(call=>call.url.includes('/get_res_privilege')));
});
test('Provider cover lookup unwraps the asynchronous Migu HTTP request into image content',async()=>{
 const e=engine(),result=await e.run('api',{path:'/api/music/pic?source=mg',body:{songInfo:{source:'mg',songmid:'456',copyrightId:'mg-456'}}});
 assert.equal(result.url,'http://image.invalid/mg/cover.jpg');assert.ok(e.calls.some(call=>call.url.includes('/getSongPic')));
});
test('Migu cover failure stops after three requests instead of recursively restarting its retry count',async()=>{
 const e=engine({miguCoverFailure:true});await assert.rejects(e.run('api',{path:'/api/music/pic?source=mg',body:{songInfo:{source:'mg',songmid:'456',copyrightId:'mg-456'}}}),/Provider artwork request failed/);
 assert.equal(e.calls.filter(call=>call.url.includes('/getSongPic')).length,3);
});

test('The iOS 15 bundle contains no unsupported lookbehind expression',()=>{const source=fs.readFileSync(path.join(__dirname,'../generated/LocalEngine.js'),'utf8');assert.ok(!source.includes('(?<=')&&!source.includes('(?<!'));});

test('Home and catalogue requests do not cancel each other in the provider SDK',async()=>{
 const e=engine();const results=await Promise.all([e.run('api',{path:'/api/music/songList/list?source=wy&sortId=new&page=1'}),e.run('api',{path:'/api/music/songList/list?source=wy&sortId=hot&page=1'})]);
 assert.equal(results[0].list[0].name,'真实 SDK 歌单');assert.equal(results[1].list[0].id,'123');assert.equal(e.calls.length,2);
});

test('NetEase comments use a provider ID stripped of the LX playlist prefix',async()=>{
 const e=engine();
 const result=await e.run('api',{path:'/api/music/comment',body:{songInfo:{id:'wy_123',meta:{source:'wy',songId:'wy_123'}},type:'hot'}});
 assert.deepEqual(result.comments,[]);
 assert.ok(e.calls.some(call=>call.url.includes('/hotcomments/R_SO_4_123')));
 assert.ok(e.calls.every(call=>!call.url.includes('/hotcomments/R_SO_4_wy_')));
});

test('Device tracks and missing provider IDs return actionable comment errors without making a request',async()=>{
 const e=engine();
 const local=await e.run('api',{path:'/api/music/comment',body:{songInfo:{source:'local',id:'123'}}});
 const missing=await e.run('api',{path:'/api/music/comment',body:{songInfo:{source:'wy'}}});
 assert.equal(local.code,'unsupported');assert.equal(missing.code,'missing-id');assert.equal(e.calls.length,0);
});
