'use strict';
const transport=require('./mediaTransport'),cloud=require('./openList');
const fail=(message,status=400)=>Object.assign(new Error(message),{status});
const safeName=s=>String(s || '音乐').replace(/[\\/\x00-\x1f:*?"<>|]/g,'_').slice(0,150);
const stem=song=>safeName([song.singer || song.meta?.singer,song.name || song.meta?.name].filter(Boolean).join(' - '));
function format(type,url='',quality=''){
 type=String(type || '').split(';')[0].toLowerCase();const types={'audio/flac':'flac','audio/x-flac':'flac','audio/mpeg':'mp3','audio/mp3':'mp3','audio/wav':'wav','audio/x-wav':'wav','audio/mp4':'m4a','audio/x-m4a':'m4a','video/mp4':'m4a','audio/aac':'aac','audio/ogg':'ogg','application/ogg':'ogg','audio/opus':'opus','audio/aiff':'aiff','image/jpeg':'jpg','image/png':'png','image/webp':'webp','image/gif':'gif'};
 const extension=types[type] || /\.(flac|mp3|m4a|aac|ogg|opus|wav|aiff|alac)(?:[?#]|$)/i.exec(url)?.[1]?.toLowerCase() || 'bin';return {extension,format:extension==='bin'?'原始格式':extension==='m4a'?'AAC / M4A':extension.toUpperCase(),mime:type || 'application/octet-stream'};
}
async function bounded(task,signal,ms=15000){return await Promise.race([task,new Promise((_,reject)=>{const timer=setTimeout(()=>reject(fail('媒体读取超时',504)),ms);timer.unref();task.finally(()=>clearTimeout(timer)).catch(()=>{});if(signal){const abort=()=>{clearTimeout(timer);reject(fail('下载已取消',410));};if(signal.aborted)abort();else{signal.addEventListener('abort',abort,{once:true});task.finally(()=>signal.removeEventListener('abort',abort)).catch(()=>{});}}})]);}
function deadline(input,controller){let timer;const expire=()=>{const remaining=input.expiresAt-Date.now();if(remaining<=0)controller.abort();else{timer=setTimeout(expire,Math.min(remaining,2147483647));timer.unref();}};if(input.expiresAt)expire();return ()=>clearTimeout(timer);}
async function resolved(song,quality,owner,deps){
 if(song.openlist){await deps.authorize?.(song);const file=await bounded(cloud.file(song.openlist.owner || owner,song.openlist));return {url:file.url,quality:'original'};}
 if(!['wy','kg','tx','kw','mg'].includes(song.source || song.meta?.source))throw fail('歌曲来源不支持下载');
 return bounded(Promise.resolve(deps.resolve({...song.meta,...song},quality,owner)));
}
async function read(url,signal,max=8*1024*1024){const response=await transport.open(url,{signal,category:'music'});if(response.statusCode!==200){response.destroy();throw fail('资料暂时不可用',404);}const chunks=[];let size=0;for await(const chunk of response){size+=chunk.length;if(size>max){response.destroy();throw fail('资料文件过大',413);}chunks.push(chunk);}return {buffer:Buffer.concat(chunks),type:response.headers['content-type'] || ''};}
async function sidecar(song,part,owner,deps,signal){
 if(song.openlist){await deps.authorize?.(song);const ref=song.openlist,base=ref.path.replace(/\.[^/.]+$/,'');for(const ext of part==='lyrics'?['lrc']:['jpg','jpeg','png','webp']){try{const file=await cloud.file(ref.owner || owner,{...ref,path:base+'.'+ext}),value=await read(file.url,signal,part==='lyrics'?2*1024*1024:8*1024*1024);if(part==='cover' && !/^image\/(jpeg|png|webp|gif)/.test(value.type))continue;return {name:stem(song)+'.'+(part==='cover'?format(value.type).extension:ext),buffer:value.buffer,mime:part==='lyrics'?'text/plain; charset=utf-8':value.type};}catch(error){if(signal?.aborted)throw error;}}throw fail(part==='lyrics'?'没有同名歌词文件':'没有同名封面文件',404);}
 if(part==='lyrics'){const result=await bounded(Promise.resolve(deps.lyric(song,owner)),signal),text=typeof result==='string'?result:result?.lyric || result?.lrc || '';if(!text)throw fail('暂无歌词',404);return {name:stem(song)+'.lrc',buffer:Buffer.from(text,'utf8'),mime:'text/plain; charset=utf-8'};}
 let url=song.meta?.picUrl || song.img || song.picUrl || song.pic;if(!/^https?:\/\//.test(url || '') || /logo\.svg/.test(url))url=await bounded(Promise.resolve(deps.cover(song,owner)),signal);if(!/^https?:\/\//.test(url || ''))throw fail('暂无封面',404);const value=await read(url,signal);if(!/^image\/(jpeg|png|webp|gif)/.test(value.type))throw fail('封面格式无效',404);return {name:stem(song)+'.'+format(value.type).extension,buffer:value.buffer,mime:value.type};
}
async function inspect(input,url,quality){
 const iterator=input.iterator({destroyOnReturn:false}),chunks=[];let length=0;
 try{while(length<32){const next=await iterator.next();if(next.done)break;chunks.push(next.value);length+=next.value.length;}await iterator.return();
 const bytes=Buffer.concat(chunks),head=bytes.subarray(0,256).toString('utf8').replace(/^\uFEFF/,'').trimStart();let detected;
 if(!bytes.length || /^[<{[]/.test(head) || /^(?:access denied|forbidden|unauthorized|error[: ]|not found)/i.test(head))throw fail('音源返回的不是音频文件，请更换音质或音源后重试',502);
 if(bytes.subarray(0,4).toString()==='fLaC')detected='audio/flac';else if(bytes.subarray(0,4).toString()==='RIFF' && bytes.subarray(8,12).toString()==='WAVE')detected='audio/wav';else if(bytes.subarray(0,3).toString()==='ID3')detected='audio/mpeg';else if(bytes[0]===255 && (bytes[1]&246)===240)detected='audio/aac';else if(bytes[0]===255 && (bytes[1]&224)===224)detected='audio/mpeg';else if(bytes.subarray(0,4).toString()==='OggS')detected='audio/ogg';else if(bytes.subarray(4,8).toString()==='ftyp')detected='audio/mp4';else if(bytes.subarray(0,4).toString()==='FORM' && ['AIFF','AIFC'].includes(bytes.subarray(8,12).toString()))detected='audio/aiff';
 if(!detected)throw fail('音频格式无法识别，未保存下载文件',502);
 const info=format(detected,url,quality),stream=require('node:stream').Readable.from((async function*(){try{for(const chunk of chunks)yield chunk;for await(const chunk of input)yield chunk;}finally{input.destroy();}})());stream.once('close',()=>input.destroy());return {stream,...info};
 }catch(error){input.destroy();throw error;}
}
async function options(song,owner,deps){
 // Some music CDNs reject HEAD. A bounded ranged GET also verifies real bytes
 // instead of presenting a signed error document as an available quality.
 const qualities=song.openlist?['original']:['flac24bit','flac','320k','128k'];const rows=await Promise.all(qualities.map(async quality=>{let response,preview;try{
 const result=await resolved(song,quality,owner,deps),signal=AbortSignal.timeout(8000);response=await transport.open(result.url,{category:'music',signal,headers:{Range:'bytes=0-4095','Accept-Encoding':'identity'}});
 if(![200,206].includes(response.statusCode))throw fail('音源暂不可用 ('+response.statusCode+')');preview=await inspect(response,result.url,result.quality || quality);const {stream,...info}=preview;
 return {quality,actualQuality:result.quality || quality,...info,available:true};}catch(error){return {quality,available:false,format:'暂不可用'};}finally{preview?.stream.destroy();response?.destroy();}}));return {qualities:rows};
}
function parts(value){const requested=Array.isArray(value)?value:typeof value==='string'?value.split(','):Object.keys(value || {}).filter(k=>value[k]===true);const valid=[...new Set(requested.filter(p=>['song','lyrics','cover'].includes(p)))];if(!valid.length)throw fail('至少勾选一项下载内容');return valid;}
async function collect(song,quality,requested,owner,deps,signal){
 const files=[],missing=[];let result;
 if(requested.includes('song')){result=await resolved(song,quality,owner,deps);const input=await transport.open(result.url,{signal,category:'music',headers:{'Accept-Encoding':'identity'}});input.on('error',()=>{});if(![200,206].includes(input.statusCode)){input.destroy();throw fail('音乐源暂时不可用',502);}const info=await inspect(input,result.url,result.quality || quality);if(!/^audio\//.test(info.mime) && !['application/octet-stream','binary/octet-stream','video/mp4','application/ogg'].includes(info.mime)){input.destroy();throw fail('音乐源格式无效',502);}files.push({name:stem(song)+'.'+info.extension,stream:info.stream,raw:input,mime:info.mime,length:input.headers['content-length'],quality:result.quality || quality,extension:info.extension});}
 try{for(const part of requested.filter(p=>p!=='song')){try{files.push(await sidecar(song,part,owner,deps,signal));}catch(error){if(signal?.aborted)throw error;missing.push(part==='lyrics'?'歌词':'封面');}}if(!files.length)throw fail('所选资料暂不可用：'+missing.join('、'),404);return {files,missing};}catch(error){for(const file of files){file.stream?.destroy();file.raw?.destroy();}throw error;}
}
async function serve(req,res,input,deps){
 const requested=parts(input.parts),controller=new AbortController(),signal=AbortSignal.any([controller.signal,...(input.signal?[input.signal]:[])]);const close=()=>{if(!res.writableFinished)controller.abort();};req.once('aborted',close);res.once('close',close);
 const clearDeadline=deadline(input,controller);let files=[];
 try{const result=await collect(input.song,input.quality || 'flac',requested,input.owner,deps,signal);files=result.files;
 const headers={'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','X-LX-Missing':encodeURIComponent(result.missing.join('、'))};
 if(files.length===1 && requested.length===1){const file=files[0];res.writeHead(200,{...headers,'Content-Type':file.mime,'Content-Disposition':"attachment; filename*=UTF-8''"+encodeURIComponent(file.name),'X-LX-Filename':encodeURIComponent(file.name),'X-LX-Quality':file.quality || input.quality || '',...(file.length?{'Content-Length':file.length}:{}),...(file.extension?{'X-LX-Extension':file.extension}:{})});if(file.stream)await require('node:stream/promises').pipeline(file.stream,res,{signal});else res.end(file.buffer);return;}
 const archive=new (await import('archiver')).ZipArchive({zlib:{level:0}});archive.on('error',error=>res.destroy(error));res.writeHead(200,{...headers,'Content-Type':'application/zip','Content-Disposition':"attachment; filename*=UTF-8''"+encodeURIComponent(stem(input.song)+'.zip')});archive.pipe(res);const abort=()=>archive.abort();signal.addEventListener('abort',abort,{once:true});try{for(const file of files)archive.append(file.stream || file.buffer,{name:file.name});if(result.missing.length)archive.append(Buffer.from('本次未能取得：'+result.missing.join('、')+'。\n其余文件已保存，封面和歌词使用与歌曲相同的文件名。','utf8'),{name:'下载说明.txt'});await archive.finalize();}finally{signal.removeEventListener('abort',abort);}
 }finally{clearDeadline();for(const file of files){file.stream?.destroy();file.raw?.destroy();}req.off('aborted',close);res.off('close',close);}
}
async function serveBatch(req,res,input,deps){
 const requested=parts(input.parts),controller=new AbortController(),signal=AbortSignal.any([controller.signal,...(input.signal?[input.signal]:[])]),archive=new (await import('archiver')).ZipArchive({zlib:{level:0}}),warnings=[],clearDeadline=deadline(input,controller);
 const close=()=>{if(!res.writableFinished){controller.abort();archive.abort();}};req.once('aborted',close);res.once('close',close);archive.on('error',error=>res.destroy(error));
 let started=false,downloaded=0;const begin=()=>{if(started)return;started=true;res.writeHead(200,{'Content-Type':'application/zip','Content-Disposition':"attachment; filename*=UTF-8''"+encodeURIComponent(safeName(input.title || '音乐歌单')+'.zip'),'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'});archive.pipe(res);};
 try{for(let i=0;i<input.songs.length;i++){
   if(signal.aborted)throw new Error('下载已取消');const song=input.songs[i];let files=[];
   try{const result=await collect(song,input.quality || 'flac',requested,input.owner,deps,signal);files=result.files;begin();downloaded+=files.length;const folder=String(i+1).padStart(3,'0')+' - '+safeName(song.name);for(const file of files){const finished=file.stream?new Promise((resolve,reject)=>{file.stream.once('end',resolve);file.stream.once('error',reject);}):null;archive.append(file.stream || file.buffer,{name:folder+'/'+file.name});if(finished)await finished;}if(result.missing.length)warnings.push((song.name || '音乐')+'：缺少'+result.missing.join('、'));}
   catch(error){if(signal.aborted)throw error;warnings.push((song.name || '音乐')+'：'+error.message);}finally{for(const file of files){file.stream?.destroy();file.raw?.destroy();}}
 }if(!downloaded)throw fail('没有可下载的文件：'+warnings.slice(0,3).join('；'),502);if(warnings.length)archive.append(Buffer.from(warnings.join('\n'),'utf8'),{name:'下载说明.txt'});await archive.finalize();
 }finally{clearDeadline();req.off('aborted',close);res.off('close',close);if(signal.aborted || !started)archive.abort();}
}
async function transfer(input,deps,signal){const result=await collect(input.song,input.quality || 'flac',parts(input.parts),input.owner,deps,signal),saved=[];try{for(const file of result.files){const stream=file.stream || require('node:stream').Readable.from(file.buffer);const item=await cloud.put(input.owner,{id:input.id,path:input.path,filename:file.name},stream,file.length || file.buffer?.length,file.mime,signal);saved.push(item.path);}return {files:saved,missing:result.missing};}finally{for(const file of result.files){file.stream?.destroy();file.raw?.destroy();}}}
module.exports={format,inspect,stem,parts,resolved,options,sidecar,collect,serve,serveBatch,transfer};
