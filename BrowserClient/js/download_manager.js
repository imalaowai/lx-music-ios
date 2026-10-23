/* Device / OpenList download queue. Only task metadata stays in this browser. */
(function(){
'use strict';
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
class DownloadManager {
  constructor(){this.tasks=[];this.archives=new Map();this.maxConcurrent=2;this.activeCount=0;this.drawer=document.getElementById('download-drawer');this.identity='';this.epoch=0;this.restoreTasks();window.addEventListener('lx-auth-change',()=>this.restoreTasks());}
  storageKey(){return 'lx_device_download_tasks:'+ (window.DeviceLibrary?.identity() || localStorage.getItem('lx_sync_user') || '_guest');}
  restoreTasks(){this.epoch++;for(const t of this.tasks)t.controller?.abort();for(const a of this.archives.values())if(a.url)URL.revokeObjectURL(a.url);this.archives.clear();this.activeCount=0;try{this.tasks=JSON.parse(sessionStorage.getItem(this.storageKey()) || '[]').map(t=>({...t,status:['waiting','downloading'].includes(t.status) || t.target?.archive?'paused':t.status}));}catch{this.tasks=[];}this.renderList();}
  saveTasks(){sessionStorage.setItem(this.storageKey(),JSON.stringify(this.tasks.map(({controller,...task})=>task)));}
  toggleDrawer(open){if(!this.drawer)return;const show=typeof open==='boolean'?open:this.drawer.classList.contains('translate-x-full');this.drawer.classList.toggle('translate-x-full',!show);this.drawer.setAttribute('aria-hidden',String(!show));this.drawer.inert=!show;this.renderList();}
  setConcurrency(n){this.maxConcurrent=Math.max(1,Math.min(5,Number(n)||2));this.processQueue();}
  updateMaxConcurrent(n){this.setConcurrency(n);}
  getStatusHtml(icon,text){return `<p class="media-empty">${esc(text)}</p>`;}
  async addTasks(songs){
    for(const song of songs){const target=song.downloadTarget || {kind:'device'};if(song.isServer)throw new Error('请选择设备或 OpenList 下载');
      const key=(song.id || song.songmid)+':'+song.quality+':'+JSON.stringify(target)+':'+JSON.stringify(song.downloadParts || ['song']);
      if(this.tasks.some(t=>t.key===key && ['waiting','downloading'].includes(t.status)))continue;
      this.tasks.push({id:window.DeviceLibrary.uuid(),key,song,quality:song.quality || 'flac',target,status:'waiting',progress:0,downloadedBytes:0,errorMsg:''});
    }this.toggleDrawer(true);this.saveTasks();this.renderList();this.processQueue();
  }
  processQueue(){this.activeCount=this.tasks.filter(t=>t.status==='downloading').length;while(this.activeCount<this.maxConcurrent){const t=this.tasks.find(t=>t.status==='waiting');if(!t)break;this.activeCount++;t.status='downloading';void this.startDownload(t);}this.renderList();void this.prepareArchives();}
  async prepareArchives(){
    for(const [id,archive]of this.archives){if(archive.url || archive.building)continue;const tasks=this.tasks.filter(t=>t.target.batchId===id);if(!tasks.length || tasks.some(t=>t.status!=='finished'))continue;archive.building=true;
      try{const blob=await window.DeviceZip([...archive.files.values()]);archive.url=URL.createObjectURL(blob);archive.filename='LX-Music-'+new Date().toISOString().slice(0,10)+'.zip';}catch(error){archive.error=error.message;}finally{archive.building=false;this.renderList();}
    }
  }
  async startDownload(task){
    const epoch=this.epoch;task.controller=new AbortController();const signal=task.controller.signal;let writer;
    try {
      const lib=window.DeviceLibrary;if(!lib)throw new Error('设备音乐库未就绪');const rawSong=task.song;
      if(Array.isArray(rawSong.downloadParts)){await this.startAssets(task,signal);}
      else if(task.target.kind==='openlist' && !rawSong.deviceKey && !rawSong.openlist){
        await lib.api('/api/openlist/transfer',{id:task.target.id,path:task.target.path,song:rawSong,quality:task.quality},signal);task.progress=100;
      } else {
        let response,blob,filename=rawSong.filename || `${rawSong.singer || '未知歌手'} - ${rawSong.name}.${String(task.quality).includes('flac')?'flac':'mp3'}`;
        if(rawSong.deviceKey)blob=await lib.blobFor(rawSong);
        else if(rawSong.openlist){const resolved=await lib.resolve(rawSong);response=await fetch(resolved.url,{signal});}
        else response=await fetch('/api/media/download',{method:'POST',headers:{'Content-Type':'application/json',...lib.ownAuth()},body:JSON.stringify({song:rawSong,quality:task.quality}),signal});
        if(response && !response.ok){const data=await response.json().catch(()=>({}));throw new Error(data.message || `下载失败 (${response.status})`);}
        if(response){
          const type=response.headers.get('content-type') || '';
          if(response.headers.get('x-lx-extension'))filename=filename.replace(/\.[^.]+$/,'.'+response.headers.get('x-lx-extension'));else if(type.includes('wav'))filename=filename.replace(/\.[^.]+$/,'.wav');else if(type.includes('flac'))filename=filename.replace(/\.[^.]+$/,'.flac');else if(type.includes('mpeg'))filename=filename.replace(/\.[^.]+$/,'.mp3');
          task.totalBytes=Number(response.headers.get('content-length')) || 0;
          const dir=task.target.kind==='device'?await lib.getDirectory('download'):null;
          if(dir && await dir.queryPermission({mode:'readwrite'})==='granted')writer=await (await lib.createDownloadFile(dir,filename)).createWritable();
          const chunks=[],reader=response.body.getReader();let updatedAt=0;
          while(true){const {value,done}=await reader.read();if(done)break;if(signal.aborted)throw new DOMException('已暂停','AbortError');
            if(writer)await writer.write(value);else chunks.push(value);task.downloadedBytes+=value.length;task.progress=task.totalBytes?Math.round(task.downloadedBytes/task.totalBytes*100):0;
            if(Date.now()-updatedAt>350){this.renderList();updatedAt=Date.now();}
          }
          if(writer){await writer.close();writer=null;}else blob=new Blob(chunks,{type});
        }
        if(signal.aborted)throw new DOMException('已暂停','AbortError');
        if(task.target.kind==='openlist'){
          const url='/api/openlist/upload?'+new URLSearchParams({id:task.target.id,path:task.target.path,filename});
          const r=await fetch(url,{method:'POST',headers:{...lib.ownAuth(),'Content-Type':blob.type || 'application/octet-stream'},body:blob,signal});const data=await r.json();if(!r.ok || data.success===false)throw new Error(data.message || '网盘上传失败');
        }else if(blob && task.target.archive){
          const archive=this.archives.get(task.target.batchId) || {files:new Map()};if([...archive.files.values()].reduce((sum,f)=>sum+f.blob.size,0)+blob.size>512*1024*1024)throw new Error('此批次超过浏览器暂存限制，请授权下载目录或使用 OpenList');archive.files.set(task.id,{filename,blob});this.archives.set(task.target.batchId,archive);
        }else if(blob)await lib.writeDevice(blob,filename,signal);
        task.progress=100;
      }
      if(epoch!==this.epoch)return;task.status='finished';task.errorMsg='';
    }catch(error){if(writer)await writer.abort().catch(()=>{});if(epoch!==this.epoch)return;task.status=signal.aborted?'paused':'error';task.errorMsg=error.message || '下载失败';}
    finally {if(epoch===this.epoch){task.controller=null;this.saveTasks();this.processQueue();}}
  }
  async startAssets(task,signal){
    const lib=window.DeviceLibrary,song=task.song,parts=song.downloadParts;task.warnings=[];
    if(task.target.kind==='openlist' && !song.deviceKey){const result=await lib.api('/api/openlist/export',{song,quality:task.quality,parts,id:task.target.id,path:task.target.path},signal);task.warnings=result.missing || [];task.progress=100;return;}
    let directory=task.target.kind==='device'?await lib.getDirectory('download'):null;
    if(directory && await directory.queryPermission({mode:'readwrite'})!=='granted')directory=null;
    if(!directory && task.target.kind==='device' && parts.length>1 && !task.target.archive){task.target={kind:'device',archive:true,batchId:lib.uuid()};}
    let archive;if(task.target.archive){archive=this.archives.get(task.target.batchId);if(!archive){archive={files:new Map(),stems:new Set()};this.archives.set(task.target.batchId,archive);}archive.stems ||= new Set();}
    let outputStem,saved=0;const baseName=filename=>filename.replace(/\.[^.]+$/,'');
    const save=async(file,part)=>{
      const extension=/\.([^.]+)$/.exec(file.filename)?.[1] || 'bin';
      if(!outputStem){const proposed=baseName(file.filename);if(directory)outputStem=await window.DownloadOptions.reserveStem(directory,proposed);else if(archive){let i=1;outputStem=proposed;while(archive.stems.has(outputStem))outputStem=proposed+' ('+(++i)+')';archive.stems.add(outputStem);}else outputStem=proposed;}
      const filename=outputStem+'.'+extension;
      if(task.target.kind==='openlist'){const blob=file.blob;const response=await fetch('/api/openlist/upload?'+new URLSearchParams({id:task.target.id,path:task.target.path,filename}),{method:'POST',headers:{...lib.ownAuth(),'Content-Type':blob.type || 'application/octet-stream'},body:blob,signal});const result=await response.json();if(!response.ok || !result.success)throw new Error(result.message || '上传失败');}
      else if(directory){const handle=await directory.getFileHandle(filename,{create:true}),writer=await handle.createWritable();try{if(file.response){const reader=file.response.body.getReader();while(true){const {done,value}=await reader.read();if(done)break;if(signal.aborted)throw new DOMException('已暂停','AbortError');await writer.write(value);task.downloadedBytes+=value.length;}}else await writer.write(file.blob);if(signal.aborted)throw new DOMException('已暂停','AbortError');await writer.close();}catch(error){await writer.abort().catch(()=>{});throw error;}}
      else {const blob=file.blob || await file.response.blob();if(signal.aborted)throw new DOMException('已暂停','AbortError');if(archive){if([...archive.files.values()].reduce((total,item)=>total+item.blob.size,0)+blob.size>512*1024*1024)throw new Error('批次暂存超过 512 MiB，请授权下载目录或保存到 OpenList');archive.files.set(task.id+':'+part,{filename,blob});}else await lib.writeDevice(blob,filename,signal);}
      saved++;
    };
    for(let i=0;i<parts.length;i++){
      if(signal.aborted)throw new DOMException('已暂停','AbortError');const part=parts[i];
      try{let file;
        if(song.deviceKey){const original=song.filename || (await lib.blobFor(song)).name,stem=baseName(original);
          if(part==='song')file={filename:original,blob:await lib.blobFor(song)};
          else if(part==='lyrics'){const text=await lib.localLyric(song);if(!text)throw new Error('没有歌词');file={filename:stem+'.lrc',blob:new Blob([text],{type:'text/plain;charset=utf-8'})};}
          else {const blob=await lib.localCover(song);if(!blob)throw new Error('没有封面');file={filename:stem+'.'+(blob.type.includes('png')?'png':blob.type.includes('webp')?'webp':'jpg'),blob};}
        }else{const response=await fetch('/api/media/export',{method:'POST',headers:{'Content-Type':'application/json',...lib.ownAuth()},body:JSON.stringify({song,quality:task.quality,parts:[part]}),signal});if(!response.ok){const result=await response.json().catch(()=>({}));throw new Error(result.message || '资料下载失败');}const filename=decodeURIComponent(response.headers.get('X-LX-Filename') || '') || song.name+(part==='lyrics'?'.lrc':part==='cover'?'.jpg':'.mp3');file={filename,response};}
        await save(file,part);
      }catch(error){if(signal.aborted || part==='song')throw error;task.warnings.push(part==='lyrics'?'歌词缺失':'封面缺失');}
      task.progress=Math.round((i+1)/parts.length*100);this.renderList();
    }
    if(!saved)throw new Error('所选资料均未能取得');
  }
  pauseTask(id){const t=this.tasks.find(t=>t.id===id);if(!t)return;if(t.status==='downloading')t.controller?.abort();t.status='paused';this.saveTasks();this.renderList();}
  resumeTask(id){const t=this.tasks.find(t=>t.id===id);if(t && ['paused','error'].includes(t.status)){Object.assign(t,{status:'waiting',downloadedBytes:0,progress:0,errorMsg:''});this.processQueue();this.saveTasks();}}
  retryTask(id){this.resumeTask(id);}
  removeTask(id){const t=this.tasks.find(t=>t.id===id);t?.controller?.abort();this.tasks=this.tasks.filter(t=>t.id!==id);this.saveTasks();this.renderList();}
  pauseAll(){for(const t of this.tasks)if(['downloading','waiting'].includes(t.status))this.pauseTask(t.id);}
  resumeAll(){for(const t of this.tasks)if(t.status==='paused')Object.assign(t,{status:'waiting',downloadedBytes:0,progress:0});this.processQueue();}
  retryAllFailed(){for(const t of this.tasks)if(t.status==='error')Object.assign(t,{status:'waiting',downloadedBytes:0,progress:0});this.processQueue();}
  retryAllLyrics(){window.showInfo?.('歌词缓存已转到设备。播放歌曲时会重新获取缺失歌词。');}
  clearCompleted(){this.tasks=this.tasks.filter(t=>t.status!=='finished');this.saveTasks();this.renderList();}
  clearAll(){this.pauseAll();for(const a of this.archives.values())if(a.url)URL.revokeObjectURL(a.url);this.archives.clear();this.tasks=[];this.saveTasks();this.renderList();}
  renderList(){
    const list=document.getElementById('download-list-container');if(!list)return;list.replaceChildren();
    const labels={waiting:'等待下载',downloading:'正在传输',paused:'已暂停',finished:'已保存',error:'失败，可重试'};
    for(const [id,a]of this.archives){const card=document.createElement('div');card.className='download-task-card';if(a.url){const link=document.createElement('a');link.className='apple-primary';link.href=a.url;link.download=a.filename;link.textContent='保存 ZIP · '+a.files.size+' 个文件';card.append(link);}else card.textContent=a.error || (a.building?'正在整理 ZIP…':'等待这批歌曲下载完成后保存 ZIP');list.append(card);}
    for(const t of this.tasks){const row=document.createElement('div');row.className='download-task-card';row.innerHTML=`<strong>${esc(t.song.name)}</strong><small>${esc(t.song.singer)} · ${t.target.kind==='openlist'?'OpenList':'此设备'} · ${esc(t.status==='finished' && t.target.archive?'待保存 ZIP':labels[t.status])}</small><progress max="100" value="${t.progress}"></progress><small>${esc(t.errorMsg || t.warnings?.join('、'))}</small><div class="media-actions"><button class="apple-link" data-action="${['waiting','downloading'].includes(t.status)?'pauseTask':'resumeTask'}">${['waiting','downloading'].includes(t.status)?'暂停':'重试 / 继续'}</button><button class="apple-link" data-action="removeTask">移除</button></div>`;for(const b of row.querySelectorAll('[data-action]'))b.onclick=()=>this[b.dataset.action](t.id);list.append(row);}
    if(!this.tasks.length)list.innerHTML='<p class="media-empty">下载到此设备，或直接传输至 OpenList 网盘。</p>';
    const speed=document.getElementById('download-global-speed');if(speed)speed.textContent=this.tasks.filter(t=>t.status==='downloading').length+' 个任务正在传输 · 下载期间请保持页面打开';
    const bar=document.getElementById('download-progress-bar'),text=document.getElementById('download-progress-text');const pct=this.tasks.length?Math.round(this.tasks.reduce((sum,t)=>sum+(t.progress || 0),0)/this.tasks.length):0;if(bar)bar.style.width=pct+'%';if(text)text.textContent=pct+'%';
  }
}
window.SystemDownloadManager=new DownloadManager();
window.toggleDownloadDrawer=open=>window.SystemDownloadManager.toggleDrawer(open);
window.SystemDownloadManager.toggleDrawer(false);
document.addEventListener('keydown',event=>{if(event.key==='Escape' && !window.SystemDownloadManager.drawer?.classList.contains('translate-x-full') && !document.querySelector('.download-options-overlay,.lx-prompt-modal,#music-share-dialog'))window.SystemDownloadManager.toggleDrawer(false);});
})();
