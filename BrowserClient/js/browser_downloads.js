/* Shared by the full player and public links: never save an API error as media. */
(function(){
'use strict';
let activeCleanup;
const safe=v=>String(v || '音乐').replace(/[\\/\x00-\x1f:*?"<>|]/g,'_').slice(0,180),MAX=500*1024*1024;
function filename(response,fallback){
 const raw=response.headers.get('x-lx-filename'),disposition=response.headers.get('content-disposition') || '';
 try{return safe(raw?decodeURIComponent(raw):decodeURIComponent(/filename\*=UTF-8''([^;]+)/i.exec(disposition)?.[1] || '') || /filename="([^"]+)"/.exec(disposition)?.[1] || fallback);}catch{return safe(fallback);}
}
async function validate(blob,name){
 if(!blob.size)throw new Error('下载文件为空');
 const bytes=new Uint8Array(await blob.slice(0,256).arrayBuffer()),text=new TextDecoder().decode(bytes).replace(/^\uFEFF/,'').trimStart();
 if(/\.lrc$/i.test(name)){if(/^(?:<!doctype|<html|\{\s*"(?:error|message|success)")/i.test(text))throw new Error('歌词接口返回错误内容');return blob;}
 if(/^[<{[]/.test(text) || /^(?:access denied|forbidden|unauthorized|error[: ]|not found)/i.test(text))throw new Error('服务器返回错误内容，未保存文件');
 const ascii=(a,b)=>String.fromCharCode(...bytes.slice(a,b));
 const audio=ascii(0,4)==='fLaC'||ascii(0,3)==='ID3'||bytes[0]===255&&(bytes[1]&224)===224||ascii(4,8)==='ftyp'||ascii(0,4)==='OggS'||ascii(0,4)==='RIFF'&&ascii(8,12)==='WAVE'||ascii(0,4)==='FORM';
 const image=bytes[0]===255&&bytes[1]===216||bytes[0]===137&&ascii(1,4)==='PNG'||ascii(0,3)==='GIF'||ascii(0,4)==='RIFF'&&ascii(8,12)==='WEBP';
 const zip=bytes[0]===80&&bytes[1]===75&&bytes[2]===3&&bytes[3]===4;
 if(!audio&&!image&&!zip)throw new Error('返回内容不是可识别的媒体文件，请更换音质或音源');
 return blob;
}
async function read(response,{signal,progress=()=>{}}={}){
 if(!response.ok){const value=await response.json().catch(()=>({}));throw new Error(value.message || value.error || '下载失败 ('+response.status+')');}
 const type=response.headers.get('content-type') || '',total=Number(response.headers.get('content-length')) || 0;
 if(/text\/html|application\/(?:json|problem\+json)/i.test(type))throw new Error('服务器没有返回媒体文件');
 if(total>MAX){await response.body?.cancel();throw new Error('文件超过 500 MiB，请分首下载或保存到 OpenList');}
 const reader=response.body?.getReader();let size=0;const chunks=[];
 if(!reader){const blob=await response.blob();if(blob.size>MAX)throw new Error('文件过大');return blob;}
 try{while(true){if(signal?.aborted)throw new DOMException('已取消下载','AbortError');const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>MAX)throw new Error('文件超过 500 MiB，请分首下载或保存到 OpenList');chunks.push(value);progress(size,total);}}
 catch(error){await reader.cancel().catch(()=>{});throw error;}
 if(total && size!==total)throw new Error('文件传输不完整，请重试');
 return new Blob(chunks,{type:type || 'application/octet-stream'});
}
function panel(){
 document.getElementById('browser-download-panel')?.remove();
 const overlay=document.createElement('div');overlay.id='browser-download-panel';overlay.className='download-options-overlay';
 overlay.innerHTML='<section class="download-options-card" role="dialog" aria-modal="true" aria-label="下载文件"><h2>下载文件</h2><p data-download-status role="status">正在连接音源…</p><progress max="100" value="0" style="width:100%"></progress><div data-download-files></div><div><button type="button" data-download-close>取消</button></div></section>';
 document.body.append(overlay);return overlay;
}
function offer(blob,name,container){
 const row=document.createElement('div'),url=URL.createObjectURL(blob),link=document.createElement('a');
 row.style.cssText='display:flex;align-items:center;gap:12px;padding:12px 0;flex-wrap:wrap';
 link.href=url;link.download=safe(name);link.className='apple-primary';link.textContent='保存 '+safe(name);row.append(link);
 let file;try{file=new File([blob],safe(name),{type:blob.type});}catch{}
 if(file&&navigator.canShare?.({files:[file]})){
  const button=document.createElement('button');button.type='button';button.className='apple-secondary';button.textContent='分享 / 存储到文件';
  button.onclick=()=>navigator.share({files:[file],title:name}).catch(e=>{if(e.name!=='AbortError')window.showError?.(e.message);});row.append(button);
 }
 container.append(row);return {link,url};
}
// Keep a visible save link after the asynchronous transfer. Its click retains
// Safari's user activation and works in installed web apps as well as browsers.
async function download(items,{title='下载文件',headers={},identity}={}){
 activeCleanup?.();
 const overlay=panel(),status=overlay.querySelector('[data-download-status]'),progress=overlay.querySelector('progress'),files=overlay.querySelector('[data-download-files]'),close=overlay.querySelector('[data-download-close]'),controller=new AbortController(),urls=[];
 let done=false,saved=0;const owner=identity?.();overlay.querySelector('h2').textContent=title;
 const clean=()=>{window.removeEventListener('lx-auth-change',authChanged);if(activeCleanup===clean)activeCleanup=null;controller.abort();overlay.remove();for(const url of urls)setTimeout(()=>URL.revokeObjectURL(url),60000);};
 const authChanged=()=>{if(identity&&owner!==identity()){clean();window.showInfo?.('账号已切换，下载已取消');}};
 activeCleanup=clean;window.addEventListener('lx-auth-change',authChanged);
 close.onclick=()=>{window.removeEventListener('lx-auth-change',authChanged);clean();};
 try{for(let i=0;i<items.length;i++){
  if(controller.signal.aborted)break;if(identity&&owner!==identity())throw new Error('账号已切换');
  const item=items[i];status.textContent=(i+1)+' / '+items.length+' · 正在获取 '+(item.name || '音乐');
  let blob,name;
  if(item.prepare){const prepared=await item.prepare();blob=prepared.blob;name=prepared.name;}else{
  const response=await fetch(item.url,{credentials:'same-origin',cache:'no-store',...item.options,headers:{...headers,...item.options?.headers},signal:controller.signal});
  blob=await read(response,{signal:controller.signal,progress:(bytes,total)=>{progress.value=total?bytes/total*100:0;status.textContent=(i+1)+' / '+items.length+' · '+(bytes/1024/1024).toFixed(1)+' MiB'+(total?' / '+(total/1024/1024).toFixed(1)+' MiB':'');}});
  name=filename(response,item.name || '音乐.zip');}
  await validate(blob,name);
  if(controller.signal.aborted)break;if(identity&&owner!==identity())throw new Error('账号已切换');
  const result=offer(blob,name,files);urls.push(result.url);saved++;progress.value=100;
  // Desktop browsers can save immediately. iOS always receives an explicit
  // user-clicked save/share control after the transfer has completed.
  if(!/(iPhone|iPad|iPod)/i.test(navigator.userAgent || '')&&!(navigator.platform==='MacIntel'&&navigator.maxTouchPoints>1))result.link.click();
 }
 if(!controller.signal.aborted){done=true;status.textContent=saved+' 个文件已就绪，点击“保存”或“分享 / 存储到文件”。';close.textContent='完成';}
 }catch(error){if(!controller.signal.aborted){status.textContent=error.message || '下载失败，请重试';close.textContent='关闭';}}
 finally{if(!overlay.isConnected)window.removeEventListener('lx-auth-change',authChanged);}
 return saved;
}
async function local(song,selection){
 if(song.offlineId)return window.QiyeOffline.bundle(song.offlineId,selection.parts);
 const files=[],lib=window.DeviceLibrary,stem=safe(song.name);
 for(const part of selection.parts){
  if(part==='song')files.push({filename:song.filename || stem+'.mp3',blob:await lib.blobFor(song)});
  else if(part==='lyrics'){const text=await lib.localLyric(song);if(text)files.push({filename:stem+'.lrc',blob:new Blob([text],{type:'text/plain;charset=utf-8'})});}
  else{const blob=await lib.localCover(song);if(blob)files.push({filename:stem+'.'+(blob.type.includes('png')?'png':'jpg'),blob});}
 }
 if(!files.length)throw new Error('没有可保存的本机文件');
 return files.length===1?{blob:files[0].blob,name:files[0].filename}:{blob:await window.DeviceZip(files),name:stem+'.zip'};
}
function songs(songs,selection){return download(songs.map(song=>song.deviceKey||song.offlineId?{name:song.name,prepare:()=>local(song,selection)}:{url:'/api/media/export',name:safe(song.name)+(selection.parts.length>1?'.zip':selection.parts[0]==='lyrics'?'.lrc':selection.parts[0]==='cover'?'.jpg':'.mp3'),options:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({song,quality:selection.quality,parts:selection.parts})}}),{title:'下载到手机 / 电脑',headers:window.DeviceLibrary.ownAuth(),identity:window.DeviceLibrary.identity});}
window.BrowserDownloads={filename,validate,read,download,songs};
})();
