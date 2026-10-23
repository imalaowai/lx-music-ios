/* Browser-owned offline files. Account credentials never enter this database. */
(function(){
'use strict';
var DB='qiye-offline-v1', STORE='files', MAX_BYTES=500*1024*1024, dbPromise;
var jobs=[], active=0, controllers=new Map(), urls=new Map(), epoch=0;
var owner=function(){return window.DeviceLibrary?.identity() || localStorage.getItem('lx_sync_user') || '_guest';};
var safe=function(value){return String(value || '音乐').replace(/[\\/:*?"<>|\u0000-\u001f]/g,'_').slice(0,150);};
var token=function(){return localStorage.getItem('lx_user_token') || '';};
function open(){
 if(!window.indexedDB)return Promise.reject(new Error('此浏览器无法使用离线存储'));
 return dbPromise || (dbPromise=new Promise(function(resolve,reject){
  var r=indexedDB.open(DB,1);
  r.onupgradeneeded=function(){r.result.createObjectStore(STORE,{keyPath:'key'});};
  r.onsuccess=function(){resolve(r.result);};r.onerror=function(){reject(r.error);};
 }));
}
async function storage(mode,action){
 var db=await open();
 return new Promise(function(resolve,reject){
  var tx=db.transaction(STORE,mode),result;
  var r=action(tx.objectStore(STORE));r.onsuccess=function(){result=r.result;};
  tx.oncomplete=function(){resolve(result);};tx.onerror=tx.onabort=function(){reject(tx.error || new Error('离线存储写入失败，请检查可用空间'));};
 });
}
function key(scope,id){return scope+'\u0000'+id;}
function objectURL(record,part){
 var blob=record[part];if(!(blob instanceof Blob))return '';
 var id=record.key+':'+part;
 if(!urls.has(id))urls.set(id,URL.createObjectURL(blob));return urls.get(id);
}
function publicRecord(record){
 var song=Object.assign({},record.song,{offlineId:record.id,isLocal:true});
 delete song.deviceKey;
 if(record.cover)song.img=objectURL(record,'cover');
 if(record.audio)song.url=objectURL(record,'audio');
 return {id:record.id,song:song,status:record.status,quality:record.quality,parts:record.parts,
  progress:record.progress || 0,error:record.error || '',hasCover:!!record.cover,hasLyric:!!record.lyrics,createdAt:record.createdAt};
}
function notify(record){
 if(record.owner===owner())window.dispatchEvent(new CustomEvent('lx-native-download',{detail:publicRecord(record)}));
}
async function list(){
 var scope=owner(),rows=await storage('readonly',function(s){return s.getAll();});
 if(scope!==owner())return [];
 var current=rows.filter(function(r){return r.owner===scope;}).sort(function(a,b){return b.createdAt-a.createdAt;});
 return current.map(function(r){
  var running=jobs.find(function(j){return j.key===r.key;});
  if(running)r=running;
  else if(['resolving','downloading'].includes(r.status)){r.status='error';r.error='上次下载中断，请重新下载';}
  return publicRecord(r);
 });
}
async function get(id,scope){
 scope=scope || owner();var record=await storage('readonly',function(s){return s.get(key(scope,id));});
 if(scope!==owner())throw new Error('账号已切换');
 if(!record || record.owner!==scope)throw new Error('未找到当前账号的本机文件');return record;
}
async function put(record){await storage('readwrite',function(s){return s.put(record);});notify(record);}
function headers(){return Object.assign({},window.getUserAuthHeaders?.() || window.DeviceLibrary?.ownAuth?.() || {});}
async function responseBlob(response,signal,progress){
 if(!response.ok){var error=await response.json().catch(function(){return {};});throw new Error(error.message || error.error || '下载失败 ('+response.status+')');}
 var type=response.headers.get('content-type') || 'application/octet-stream';
 if(/text\/html|application\/json/i.test(type))throw new Error('服务器没有返回可保存的媒体文件');
 var total=Number(response.headers.get('content-length')) || 0;
 if(total>MAX_BYTES)throw new Error('单个离线文件超过 500 MiB');
 var reader=response.body?.getReader(),parts=[],bytes=0,last=0;
 if(!reader){var blob=await response.blob();if(blob.size>MAX_BYTES)throw new Error('离线文件过大');return blob;}
 while(true){
  if(signal?.aborted)throw new DOMException('下载已取消','AbortError');
  var next=await reader.read();if(next.done)break;
  bytes+=next.value.length;if(bytes>MAX_BYTES){await reader.cancel();throw new Error('单个离线文件超过 500 MiB');}
  parts.push(next.value);
  if(Date.now()-last>250){progress(total?bytes/total:0);last=Date.now();}
 }
 if(!bytes)throw new Error('下载文件为空');return new Blob(parts,{type:type});
}
function filename(response,fallback){
 try{return safe(decodeURIComponent(response.headers.get('x-lx-filename') || '') || fallback);}catch{return safe(fallback);}
}
async function part(record,name,signal){
 var song=record.song;
 if(song.deviceKey){
  if(name==='song')return {blob:await window.DeviceLibrary.blobFor(song),name:safe(song.filename || song.name+'.mp3')};
  if(name==='lyrics'){var lyric=await window.DeviceLibrary.localLyric(song);if(!lyric)throw new Error('未找到歌词');return {text:lyric,name:safe(song.name+'.lrc')};}
  var cover=await window.DeviceLibrary.localCover(song);if(!cover)throw new Error('未找到封面');return {blob:cover,name:safe(song.name+'.jpg')};
 }
 var response=await fetch('/api/media/export',{method:'POST',credentials:'same-origin',headers:Object.assign({'Content-Type':'application/json'},headers()),
  body:JSON.stringify({song:song,quality:record.quality,parts:[name]}),signal:signal});
 var blob=await responseBlob(response,signal,function(p){record.progress=Math.min(99,Math.round((record.doneParts+p)/record.parts.length*100));notify(record);});
 var out={blob:blob,name:filename(response,song.name+(name==='lyrics'?'.lrc':name==='cover'?'.jpg':String(record.quality).includes('flac')?'.flac':'.mp3'))};
 if(window.BrowserDownloads)await window.BrowserDownloads.validate(blob,out.name);
 if(name==='lyrics')out.text=await blob.text();return out;
}
function pump(){
 while(active<2){
  var record=jobs.find(function(j){return j.status==='resolving';});if(!record)return;
  record.status='downloading';active++;run(record).finally(function(){active--;pump();});
 }
}
async function run(record){
 var controller=new AbortController(),currentEpoch=epoch,identity=token();controllers.set(record.key,controller);
 try{
  record.doneParts=0;var warnings=[];
  for(var name of record.parts){
   if(currentEpoch!==epoch || record.owner!==owner() || identity!==token())throw new DOMException('账号已切换','AbortError');
   try{
    var file=await part(record,name,controller.signal);
    if(name==='song'){record.audio=file.blob;record.audioName=file.name;}
    if(name==='lyrics')record.lyrics=file.text;
    if(name==='cover'){record.cover=file.blob;record.coverName=file.name;}
   }catch(error){if(name==='song' || controller.signal.aborted)throw error;warnings.push(name==='lyrics'?'未取得歌词':'未取得封面');}
   record.doneParts++;record.progress=Math.round(record.doneParts/record.parts.length*100);notify(record);
  }
  if(controller.signal.aborted || currentEpoch!==epoch || identity!==token())throw new DOMException('下载已取消','AbortError');
  if(!record.audio && !record.lyrics && !record.cover)throw new Error('未能保存所选内容');
  record.status=record.audio?'finished':'assets';record.error=warnings.join(' · ');record.progress=100;
 }catch(error){
  record.status='error';record.error=error.name==='AbortError'?'下载已取消，可重新下载':error.message;
 }
 finally{
  controllers.delete(record.key);jobs=jobs.filter(function(j){return j!==record;});
  if(!record.removed)await put(record).catch(function(error){record.status='error';record.error=error.message;notify(record);});
 }
}
async function add(song,quality,parts){
 if(song.offlineId){var existingOwner=owner(),existing=await storage('readonly',function(s){return s.get(key(existingOwner,song.offlineId));});if(existingOwner!==owner())throw new Error('账号已切换');if(existing && ['finished','assets'].includes(existing.status))return publicRecord(existing);}
 var clean=Object.assign({},song);delete clean.url;delete clean.offlineId;
 // Existing device file references are resolved only within the same account.
 var scope=owner(),id=window.DeviceLibrary.uuid(),requested=Array.isArray(parts)?parts:['song','lyrics','cover'];
 requested=['song','lyrics','cover'].filter(function(p){return requested.includes(p);});
 if(!requested.length)throw new Error('请选择要保存的内容');
 var record={key:key(scope,id),owner:scope,id:id,song:clean,quality:quality || 'flac',parts:requested,status:'resolving',progress:0,createdAt:Date.now()};
 await put(record);jobs.push(record);pump();return publicRecord(record);
}
async function remove(id){
 var scope=owner(),record=await get(id,scope),job=jobs.find(function(j){return j.key===record.key;});
 if(job){job.removed=true;job.status='error';if(!controllers.has(record.key))jobs=jobs.filter(function(j){return j!==job;});}controllers.get(record.key)?.abort();
 await storage('readwrite',function(s){return s.delete(record.key);});
 for(var entry of urls){if(entry[0].startsWith(record.key+':')){URL.revokeObjectURL(entry[1]);urls.delete(entry[0]);}}
 if(scope===owner())window.dispatchEvent(new CustomEvent('lx-native-download',{detail:{id:id,deleted:true}}));
}
async function cancel(id){
 var record=jobs.find(function(j){return j.id===id && j.owner===owner();});
 if(record){record.status='error';record.error='下载已取消，可重新下载';
  if(controllers.has(record.key)){controllers.get(record.key).abort();notify(record);}
  else{jobs=jobs.filter(function(j){return j!==record;});await put(record);}
 }
}
async function play(id){
 var scope=owner(),selected=await get(id,scope);
 if(!selected.audio)throw new Error('这条记录没有保存音频');
 try{await window.BrowserDownloads.validate(selected.audio,selected.audioName || '音乐.mp3');}
 catch(error){selected.status='error';selected.error='这首离线文件无效，请删除后重新下载：'+error.message;await put(selected);throw new Error(selected.error);}
 var rows=await storage('readonly',function(s){return s.getAll();});
 if(scope!==owner())throw new Error('账号已切换');
 var queue=rows.filter(function(r){return r.owner===scope && r.status==='finished' && r.audio;}).sort(function(a,b){return b.createdAt-a.createdAt;}).map(function(r){return publicRecord(r).song;});
 var index=queue.findIndex(function(s){return s.offlineId===id;});if(index<0)throw new Error('本机音频不可用');
 window.__LX_PLAYER_GETTERS__.setRoomPlaylist(queue,index);await window.playSong(queue[index],index);
 return true;
}
function saveBlob(blob,name){
 var url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=safe(name);document.body.append(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},60000);
}
async function bundle(id,parts){
 var scope=owner(),r=await get(id,scope),files=[];parts=parts || ['song','lyrics','cover'];
 if(parts.includes('song') && r.audio)await window.BrowserDownloads.validate(r.audio,r.audioName || '音乐.mp3');
 if(parts.includes('song') && r.audio)files.push({blob:r.audio,filename:r.audioName || safe(r.song.name+'.mp3')});
 if(parts.includes('lyrics') && r.lyrics)files.push({blob:new Blob([r.lyrics],{type:'text/plain;charset=utf-8'}),filename:safe(r.song.name+'.lrc')});
 if(parts.includes('cover') && r.cover)files.push({blob:r.cover,filename:r.coverName || safe(r.song.name+'.jpg')});
 if(!files.length)throw new Error('没有可分享的本机文件');
 var blob=files.length===1?files[0].blob:await window.DeviceZip(files);
 if(scope!==owner())throw new Error('账号已切换');return {blob:blob,name:files.length===1?files[0].filename:safe(r.song.name+'.zip')};
}
async function share(id){
 await window.BrowserDownloads.download([{name:'本机音乐',prepare:function(){return bundle(id);}}],{title:'分享已下载音乐',identity:owner});return true;
}
async function assets(id){var r=await get(id);return {lyric:r.lyrics || '',cover:r.cover?objectURL(r,'cover'):''};}
async function importFiles(files){
 var scope=owner(),audio=Array.from(files).filter(function(f){return /\.(mp3|flac|m4a|aac|ogg|opus|wav|aiff|aif|alac)$/i.test(f.name);}),all=Array.from(files);
 if(!audio.length)throw new Error('请选择音频文件，可同时选择同名歌词和封面');
 for(var file of audio){
  if(scope!==owner())throw new Error('账号已切换');if(file.size>MAX_BYTES)throw new Error('单个音频超过 500 MiB');
  var stem=file.name.replace(/\.[^.]+$/,''),id=window.DeviceLibrary.uuid(),lyric=all.find(function(f){return f.name.toLowerCase()===(stem+'.lrc').toLowerCase();});
  var cover=all.find(function(f){return f.name.replace(/\.[^.]+$/,'').toLowerCase()===stem.toLowerCase() && /\.(jpg|jpeg|png|webp)$/i.test(f.name);});
  var r={key:key(scope,id),owner:scope,id:id,createdAt:Date.now(),song:{id:'offline_'+id,name:stem,singer:'本机音乐',source:'local',isLocal:true,filename:file.name},quality:'original',parts:['song'],status:'finished',progress:100,audio:file,audioName:safe(file.name)};
  if(lyric){r.lyrics=await lyric.text();r.parts.push('lyrics');}if(cover){r.cover=cover;r.coverName=safe(cover.name);r.parts.push('cover');}
  await put(r);
 }
 return audio.length;
}
function chooseImport(){
 return new Promise(function(resolve,reject){
  var input=document.createElement('input');input.type='file';input.multiple=true;input.accept='audio/*,.flac,.mp3,.m4a,.lrc,.jpg,.jpeg,.png,.webp';input.hidden=true;document.body.append(input);
  input.onchange=function(){importFiles(input.files).then(resolve,reject).finally(function(){input.remove();});};
  input.addEventListener('cancel',function(){input.remove();resolve(false);},{once:true});input.click();
 });
}
function reset(){
 epoch++;for(var c of controllers.values())c.abort();for(var entry of urls)URL.revokeObjectURL(entry[1]);urls.clear();
 window.dispatchEvent(new CustomEvent('lx-native-sources'));
}
window.addEventListener('lx-auth-change',reset);window.addEventListener('lx-auth-revoked',reset);
window.QiyeOffline={list:list,add:add,bundle:bundle,remove:remove,cancel:cancel,play:play,share:share,assets:assets,chooseImport:chooseImport,importFiles:importFiles};
})();
