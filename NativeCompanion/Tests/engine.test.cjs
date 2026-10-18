const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
function engine(){
 const calls=[],pending=new Map();let sequence=0,context;
 const http=(id,json)=>{const request=JSON.parse(json);calls.push(request);let body={ok:true,url:'https://audio.invalid/song.mp3'};
  if(request.url.includes('search.kuwo.cn'))body={TOTAL:'1',abslist:[{MUSICRID:'MUSIC_123',SONGNAME:'测试歌曲',ARTIST:'歌手',ALBUM:'专辑',DURATION:'180',N_MINFO:'level:standard,bitrate:128,format:mp3,size:3.2Mb',SONGID:'123'}]};
  if(request.url.includes('/song/lyric'))body={code:200,lrc:{lyric:'[00:00.00]本机歌词'},tlyric:{lyric:'[00:00.00]Local lyrics'}};
  const payload=Buffer.from(JSON.stringify(body));queueMicrotask(()=>context.__nativeReply(id,JSON.stringify({statusCode:200,headers:{'content-type':'application/json'},base64:payload.toString('base64'),text:payload.toString()}),''));
 };
 context={__nativeRandom:n=>crypto.randomBytes(n).toString('base64'),__nativeHTTP:http,__nativeCancel(){},__nativeTimer:(id,delay)=>{const timer=setTimeout(()=>context.__runTimer(id),delay);timer.unref();},__nativeURL:(value,base)=>{const u=new URL(value,base||undefined);return JSON.stringify({origin:u.origin,protocol:u.protocol,host:u.host,hostname:u.hostname,port:u.port,pathname:u.pathname,search:u.search,hash:u.hash});},__nativeComplete:(id,json,error)=>{const item=pending.get(id);if(!item)return;pending.delete(id);clearTimeout(item.timer);error?item.reject(new Error(error)):item.resolve(JSON.parse(json));},console};
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

test('The iOS 15 bundle contains no unsupported lookbehind expression',()=>{const source=fs.readFileSync(path.join(__dirname,'../generated/LocalEngine.js'),'utf8');assert.ok(!source.includes('(?<=')&&!source.includes('(?<!'));});
