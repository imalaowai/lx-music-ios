/* Manual account synchronization shared by the Web UI and bundled IPA UI. */
(function(){
'use strict';
const $=id=>document.getElementById(id),clone=value=>JSON.parse(JSON.stringify(value)),same=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
let active=null,generation=0;const writes=new Set();
function identity(){const h=window.getUserAuthHeaders?.() || {};return JSON.stringify([localStorage.getItem('lx_sync_user') || '',h['x-user-token'] || '']);}
function watchWrites(){const original=window.pushDataChange;if(typeof original!=='function' || original.__librarySyncTracked)return;
 const tracked=function(){const args=arguments,self=this,task=Promise.resolve().then(()=>original.apply(self,args));writes.add(task);task.then(()=>writes.delete(task),()=>writes.delete(task));return task;};tracked.__librarySyncTracked=true;window.pushDataChange=tracked;
}
function valid(data){if(!data || !Array.isArray(data.defaultList) || !Array.isArray(data.loveList) || !Array.isArray(data.userList))throw new Error('服务端返回的歌单数据不完整，已保留当前歌单');return data;}
function merge(base,current,remote){
 const result={...remote,username:current.username},conflicts=[];
 for(const key of ['defaultList','loveList']){result[key]=same(base[key],current[key])?remote[key]:current[key];if(!same(base[key],current[key]) && !same(current[key],remote[key]))conflicts.push(key);}
 const old=new Map(base.userList.map(list=>[list.id,list])),now=new Map(current.userList.map(list=>[list.id,list])),fresh=new Map(remote.userList.map(list=>[list.id,list]));result.userList=[];
 const ids=[...remote.userList.map(list=>list.id),...current.userList.map(list=>list.id).filter(id=>!fresh.has(id))];
 for(const id of ids){const a=old.get(id),b=now.get(id),c=fresh.get(id);if(!same(a,b)){if(b)result.userList.push(b);if(!same(b,c))conflicts.push(id);}else if(c)result.userList.push(c);}
 return {data:result,conflicts};
}
function busy(on){const button=$('personal-sync-lists');if(button){button.disabled=on;button.textContent=on?'正在同步…':'立即同步';button.setAttribute('aria-busy',String(on));}}
async function nativeLibrary(data){
 const owner=identity();
 if(window.LXBridge?.publishLibrary)await window.LXBridge.publishLibrary(data);
 if(owner!==identity())throw Object.assign(new Error('账号已切换，已取消旧账号同步'),{name:'AbortError'});
 if(window.NativeShell?.saveLibrary)await window.NativeShell.saveLibrary(data);
 else await window.ListStore?.set(data);
}
function refreshView(){
 window.LibraryHub?.render();const view=$('view-search'),id=window.currentViewingListId;
 if(id && view && !view.classList.contains('hidden') && view.getClientRects().length){
  const scroll=view.scrollTop;window.handleListClick?.(id,true,true);view.scrollTop=scroll;
 }
 window.dispatchEvent(new CustomEvent('lx-library-updated'));
}
async function postSync(listId,signal){
 const headers={...window.getUserAuthHeaders?.(),'Content-Type':'application/json'};
 const response=await fetch('/api/user/subscriptions/sync',{method:'POST',cache:'no-store',credentials:'same-origin',headers,body:JSON.stringify(listId?{listId}:{}),signal});
 const value=await response.json().catch(()=>({}));
 if(!response.ok || value.success===false){if(response.status===404)throw new Error('服务器尚未支持立即同步，请先升级配套 Web/服务端修复包');throw new Error(value.message || value.error || '歌单同步失败（'+response.status+'）');}
 valid(value.data);return value;
}
function report(result,conflicts){
 const errors=result.errors || [],summary=result.summary || {},preserved=conflicts.length+(summary.skipped || 0);
 const status=$('playlist-subscription-status');if(status)status.textContent=errors.length?errors.map(e=>e.name+'：'+e.message).join('；'):'已同步 · '+new Date(result.syncedAt || Date.now()).toLocaleTimeString();
 if(errors.length || preserved)window.showInfo?.('歌单已刷新'+(summary.failed?'，'+summary.failed+' 个同步失败':'')+(preserved?'，'+preserved+' 处编辑已保留':'')+'。'+(errors[0]?.message || ''));
 else window.showSuccess?.('歌单已同步'+(summary.updated?'，更新 '+summary.updated+' 张歌单':'，已是最新内容'));
}
function run(options={}){
 watchWrites();const owner=identity();
 if(!window.getUserAuthHeaders?.()['x-user-token']){const error=new Error('请先登录同步账号');window.showInfo?.(error.message);return Promise.reject(error);}
 if(active?.owner===owner){window.showInfo?.('正在同步，请稍候');if(!active.listId || active.listId===options.listId)return active.promise;return active.promise.then(()=>run(options));}
 const version=++generation,controller=new AbortController(),job={owner,listId:options.listId,controller};active=job;busy(true);const status=$('playlist-subscription-status');if(status)status.textContent='正在读取最新歌单…';
 const check=()=>{if(version!==generation || owner!==identity())throw Object.assign(new Error('账号已切换，已取消旧账号同步'),{name:'AbortError'});};
 job.promise=(async()=>{
  try{
   for(let pass=0;pass<3 && writes.size;pass++)await Promise.all([...writes]);check();
   const base=clone(valid(window.__LX_LIBRARY_GETTERS__.getData())),result=await postSync(options.listId,controller.signal);check();
   const current=valid(window.__LX_LIBRARY_GETTERS__.getData()),merged=merge(base,current,result.data);check();
   window.__LX_LIBRARY_GETTERS__.adopt(merged.data);await nativeLibrary(merged.data);check();refreshView();report(result,merged.conflicts);return {...result,conflicts:merged.conflicts};
  }catch(error){if(error.name!=='AbortError' && owner===identity()){if(status)status.textContent=error.message;window.showError?.(error.message);}throw error;}
  finally{if(active===job){active=null;busy(false);}}
 })();return job.promise;
}
window.LibrarySync={run,refreshView,nativeLibrary,revision:()=>generation,isRunning:()=>!!active,merge};
window.addEventListener('lx-auth-change',()=>{generation++;active?.controller.abort();active=null;busy(false);});
if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',()=>setTimeout(watchWrites,0));else setTimeout(watchWrites,0);
})();
