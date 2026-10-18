'use strict';
const network=require('./platform.cjs'),crypto=require('crypto'),compression=require('./compression.cjs');
const providers={kw:require('../vendor/server/modules/utils/musicSdk/kw').default,kg:require('../vendor/server/modules/utils/musicSdk/kg').default,tx:require('../vendor/server/modules/utils/musicSdk/tx').default,wy:require('../vendor/server/modules/utils/musicSdk/wy').default,mg:require('../vendor/server/modules/utils/musicSdk/mg').default};
const sources=new Map(),cache=new Map();
const metadata=(script,fallback)=>Object.fromEntries(['name','version','author','description','homepage'].map(field=>[field,new RegExp('@'+field+'\\s+([^\\r\\n*]+)').exec(script)?.[1]?.trim() || (field==='name'?fallback:'')]));
async function importSource(input){
 const id=input.id,info=metadata(input.script,input.name||'本地音源');let registered={},handler;
 const record={id,...info,enabled:input.enabled!==false,sources:registered,handler:null};
 let finish,fail;const initialized=new Promise((resolve,reject)=>{finish=resolve;fail=reject;});
 const lx={version:'2.0.0',env:'desktop',platform:'ios',currentScriptInfo:{...info,rawScript:input.script},EVENT_NAMES:{request:'request',inited:'inited',updateAlert:'updateAlert'},
  on(event,callback){if(event==='request')handler=callback;},
  send(event,data){if(event==='inited'){registered=data?.sources||{};record.sources=registered;finish();}return Promise.resolve();},
  request(url,options,callback){const task=network.httpFetch(url,options||{});task.promise.then(response=>callback(null,response,response.body),error=>callback(error));return ()=>task.cancelHttp();},
  utils:{buffer:{from:(value,encoding)=>Buffer.from(value,encoding),bufToString:(value,encoding)=>Buffer.from(value).toString(encoding)},crypto:{md5:value=>crypto.createHash('md5').update(value||'').digest('hex'),aesEncrypt:(value,mode,key,iv)=>{const cipher=crypto.createCipheriv('aes-'+key.length*8+'-'+mode,key,iv);return Buffer.concat([cipher.update(value),cipher.final()]);},rsaEncrypt:(value,key)=>crypto.publicEncrypt(key,value),randomBytes:crypto.randomBytes},zlib:{inflate:value=>Promise.resolve(compression.inflateSync(value)),deflate:value=>Promise.resolve(compression.deflateSync(value))}}};
 const timer=setTimeout(()=>fail(new Error('音源初始化超时，请检查脚本是否调用 lx.send("inited")')),8000);
 try{
  const safeRequire=name=>{if(name==='crypto')return crypto;if(name==='buffer')return {Buffer};if(name==='zlib')return compression;throw new Error('手机音源不支持 Node 模块 '+name);};
  new Function('lx','require','Buffer',input.script+'\n//# sourceURL=imported-music-source.js')(lx,safeRequire,Buffer);
  await initialized;if(typeof handler!=='function'||!Object.keys(registered).some(k=>providers[k]))throw new Error('脚本未注册可用的平台和请求处理器');
  record.handler=handler;sources.set(id,record);return listSources();
 }finally{clearTimeout(timer);}
}
function listSources(){return [...sources.values()].map(({handler,...source})=>({...source,supportedSources:Object.keys(source.sources),status:'success'}));}
async function resolveSong(song,quality='flac',fallback=true){
 const raw=song.meta?{...song.meta,...song,songmid:song.songmid||song.meta.songId,source:song.source||song.meta.source}:song;
 const available=[...sources.values()].filter(x=>x.enabled&&x.sources[raw.source]);
 if(!available.length)throw new Error('请在“我的 → 音源管理”导入支持此平台的音源脚本');
 let failure;for(const source of available){
  const supported=source.sources[raw.source]?.qualitys||source.sources[raw.source]?.qualities||['128k','320k','flac'];
  const qualities=[quality,...fallback?['flac','320k','128k']:[]].filter((q,i,a)=>a.indexOf(q)===i&&supported.includes(q));
  for(const type of qualities){try{const value=await source.handler({source:raw.source,action:'musicUrl',info:{musicInfo:raw,type}});const url=typeof value==='string'?value:value?.url;if(!/^https?:\/\//i.test(url||''))throw new Error('音源没有返回有效的播放地址');return {url,type,sourceId:source.id};}catch(e){failure=e;}}
 }
 throw failure||new Error('该音源不支持选择的音质');
}
globalThis.__localResolve=(source,song,type)=>resolveSong({...song,source},type,true);
function sourceFor(query){const source=query.source||'kw';if(!providers[source])throw new Error('此平台暂不可用');return providers[source];}
async function route(input){
 const url=new URL(input.path,'https://local.invalid/'),path=url.pathname,q=Object.fromEntries(url.searchParams),body=input.body||{},source=sourceFor(q);
 switch(path){
  case '/api/music/config':return {'player.enableAuth':false,'room.syncEnabled':true,'room.syncOnTrack':true,'user.enablePublicRestriction':false};
  case '/api/music/search':{if(q.type&&q.type!=='song'){const method={singer:'searchSinger',album:'searchAlbum',playlist:'searchPlaylist'}[q.type];if(!method||!source.extendSearch?.[method])throw new Error('此平台不支持这一搜索类型');return (await source.extendSearch[method](q.name,Number(q.page)||1,20)).list||[];}const output=[];for(let i=0;i<Math.min(3,Number(q.pages)||1);i++){const result=await source.musicSearch.search(q.name,(Number(q.page)||1)+i,20);output.push(...result.list||[]);if((result.list||[]).length<20)break;}return output;}
  case '/api/music/tipSearch':return source.tipSearch?await source.tipSearch.search(q.name):[];
  case '/api/music/hotSearch':return source.hotSearch?await source.hotSearch.getList():[];
  case '/api/music/songList/tags':return {...await source.songList.getTags(),sortList:source.songList.sortList};
  case '/api/music/songList/list':return source.songList.getList(q.sortId||'new',q.tagId||'',Number(q.page)||1);
  case '/api/music/songList/detail':return source.songList.getListDetail(q.id,Number(q.page)||1);
  case '/api/music/songList/search':return source.songList.search(q.text||q.name,Number(q.page)||1);
  case '/api/music/songList/userPlaylist':return source.userPlaylist.getList(q.uid,Number(q.page)||1);
  case '/api/music/leaderboard/boards':return source.leaderboard.getBoards();
  case '/api/music/leaderboard/list':return source.leaderboard.getList(q.bangid,Number(q.page)||1);
  case '/api/music/lyric':return source.getLyric({...q,...body.songInfo});
  case '/api/music/pic':return {url:await source.getPic({...q,...body.songInfo})};
  case '/api/music/url':return resolveSong(body.songInfo,body.quality,body.allowQualityFallback!==false);
  case '/api/music/comment':return sourceFor(body.songInfo).comment.getComment(body.songInfo,body.page||1,body.limit||20);
  case '/api/custom-source/list':return listSources();
  default:throw new Error('此功能需要连接同步服务器');
 }
}
globalThis.__engineRun=(id,operation,payload)=>{
 Promise.resolve().then(async()=>{
  const input=JSON.parse(payload||'{}');
  if(operation==='import')return importSource(input);
  if(operation==='sources')return listSources();
  if(operation==='remove'){sources.delete(input.id);return listSources();}
  if(operation==='enable'){if(sources.has(input.id))sources.get(input.id).enabled=!!input.enabled;return listSources();}
  if(operation==='resolve')return resolveSong(input.song,input.quality,input.allowFallback!==false);
  const key=input.path+'|'+JSON.stringify(input.body||{}),ttl=/hotSearch|songList\/list|leaderboard\/boards/.test(input.path)?300000:0;
  const cached=cache.get(key);if(ttl&&cached&&Date.now()-cached.at<ttl)return cached.value;
  const value=await route(input);if(ttl){if(cache.size>20)cache.clear();cache.set(key,{at:Date.now(),value});}return value;
 }).then(result=>__nativeComplete(id,JSON.stringify(result??null),''),error=>__nativeComplete(id,'null',error?.message||String(error)));
};
