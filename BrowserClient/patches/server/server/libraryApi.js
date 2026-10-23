'use strict';
const crypto=require('node:crypto');
const {pipeline}=require('node:stream/promises');
const cloud=require('./openList'),social=require('./roomSocial'),transport=require('./mediaTransport');
const tickets=new Map(),locks=new Map();
let syncStarted=false;
function startSubscriptionSync(listManage){
  if(syncStarted)return;syncStarted=true;let running=false;
  const run=async()=>{if(running)return;running=true;try{
    for(const user of global.lx.config.users || [])await serial(user.name,()=>social.refreshSubscriptions(user.name,listManage)).catch(error=>console.warn('[歌单订阅]',error.message));
    await require('./task/networkListTask').checkAllUsersNetworkLists();
  }catch(error){console.warn('[歌单订阅]',error.message);}finally{running=false;}};
  setInterval(run,5*60*1000).unref();setTimeout(run,3000).unref();
}
const cloudKey=s=>JSON.stringify([s.owner,s.id,cloud.normalizePath(s.path)]);
function granted(room,ref){
  if(!room?.cloudGrants)return false;if(room.cloudGrants.has(cloudKey(ref)))return true;
  if(!/\.lrc$/i.test(ref.path))return false;
  const base=cloud.normalizePath(ref.path).replace(/\.[^.]+$/,'');
  return [...room.cloudGrants].some(key=>{const [owner,id,file]=JSON.parse(key);return owner===ref.owner && id===ref.id && file.replace(/\.[^.]+$/,'')===base;});
}
function authorizeRoomMedia(room,state,participant){
  const grants=room.cloudGrants ||= new Set(),pending=[];
  for(const song of [state.song,...(Array.isArray(state.playlist)?state.playlist:[])]){
    if(!song?.openlist)continue;
    const ref=song.openlist,key=cloudKey(ref);
    if(ref.owner===participant.name){const item=cloud.connection(ref.owner,ref.id);cloud.allowedPath(item,ref.path);if(!cloud.audioExtension.test(ref.path))throw new Error('房间仅可分享音乐文件');pending.push(key);}
    else if(!grants.has(key))throw new Error('其他账号尚未分享这首网盘音乐');
  }
  for(const key of pending)grants.add(key);
}
setInterval(()=>{for(const [key,t] of tickets)if(t.expiresAt<Date.now())tickets.delete(key);},60000).unref();
async function serial(username,task){const previous=locks.get(username) || Promise.resolve();const next=previous.catch(()=>{}).then(task);locks.set(username,next);try{return await next;}finally{if(locks.get(username)===next)locks.delete(username);}}
function respond(res,status,data){if(res.headersSent)return;res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'private, no-store'});res.end(JSON.stringify(data));}
function readJson(req){return new Promise((resolve,reject)=>{
  const chunks=[];let size=0,finished=false;
  req.on('data',chunk=>{if(finished)return;size+=chunk.length;if(size>1024*1024){finished=true;reject(Object.assign(new Error('请求内容过大'),{status:413}));return;}chunks.push(chunk);});
  req.on('end',()=>{if(finished)return;try{resolve(JSON.parse(Buffer.concat(chunks).toString() || '{}'));}catch{reject(new Error('请求数据无效'));}});req.on('error',reject);
});}
async function handle(req,res,url,deps){
  const route=url.pathname;
  if(!route.startsWith('/api/openlist/') && !route.startsWith('/api/room/chat') && !route.startsWith('/api/room/playlist') && !route.startsWith('/api/user/subscriptions') && !['/api/media/download','/api/media/options','/api/media/export'].includes(route))return false;
  const abort=new AbortController();req.once('aborted',()=>abort.abort());res.once('close',()=>{if(!res.writableFinished)abort.abort();});req.__mediaSignal=abort.signal;
  try {
    // Media URLs carry only short-lived, account-bound opaque tickets.
    if(route==='/api/openlist/stream'){
      const ticket=tickets.get(url.searchParams.get('ticket'));
      if(!ticket || ticket.expiresAt<Date.now())throw Object.assign(new Error('播放链接已过期，请重新播放'),{status:401});
      req.headers['x-user-token']=url.searchParams.get('token') || req.headers['x-user-token'];
      const username=deps.verify(req);
      if(username!==ticket.viewer)throw Object.assign(new Error('无权播放此文件'),{status:403});
      if(!global.lx.config.users.some(u=>u.name===ticket.owner))throw Object.assign(new Error('分享账号已不存在'),{status:403});
      if(ticket.owner!==username && !(deps.binding(username)?.roomId===ticket.roomId && deps.binding(ticket.owner)?.roomId===ticket.roomId && granted(deps.room(ticket.roomId),ticket)) && !await social.hasMediaGrant(username,ticket,deps.listManage))throw Object.assign(new Error('这首音乐尚未授权给此账号'),{status:403});
      const result=await cloud.file(ticket.owner,ticket);
      await require('./mediaPlayback').serve(result.url,req,res);return true;
    }
    const username=deps.verify(req) || (['/api/media/download','/api/media/options','/api/media/export'].includes(route) && global.lx.config['user.enablePublicNonAdminBrowserDownload']!==false ? '_open' : null);
    if(!username)throw Object.assign(new Error('请先登录账号'),{status:401});
    if(req.method==='GET' && route==='/api/openlist/config'){respond(res,200,{success:true,connections:cloud.views(username)});return true;}
    if(req.method==='POST' && route==='/api/openlist/upload'){
      const result=await cloud.put(username,{id:url.searchParams.get('id'),path:url.searchParams.get('path'),filename:url.searchParams.get('filename')},req,req.headers['content-length'],req.headers['content-type'],abort.signal);
      respond(res,200,{success:true,...result});return true;
    }
    const body=req.method==='POST' ? await readJson(req) : {};
    const exportDeps={...deps,authorize:async song=>{if(!song.openlist)return;const ref={...song.openlist,owner:song.openlist.owner || username,path:cloud.normalizePath(song.openlist.path)},roomId=deps.binding(username)?.roomId;if(ref.owner!==username && !(roomId && deps.binding(ref.owner)?.roomId===roomId && granted(deps.room(roomId),ref)) && !await social.hasMediaGrant(username,ref,deps.listManage))throw Object.assign(new Error('无权读取此音乐的资料'),{status:403});cloud.allowedPath(cloud.connection(ref.owner,ref.id),ref.path);if(!cloud.audioExtension.test(ref.path))throw new Error('仅支持音乐文件');}};
    if(route==='/api/media/options' && req.method==='POST'){respond(res,200,{success:true,...await require('./mediaExports').options(body.song,username,exportDeps)});return true;}
    if(route==='/api/media/export' && req.method==='POST'){await require('./mediaExports').serve(req,res,{...body,owner:username,signal:abort.signal},exportDeps);return true;}
    if(route==='/api/openlist/export' && req.method==='POST'){respond(res,200,{success:true,...await require('./mediaExports').transfer({...body,owner:username},exportDeps,abort.signal)});return true;}
    if(route==='/api/openlist/config' && req.method==='POST'){respond(res,200,{success:true,connections:cloud.save(username,body)});return true;}
    if(route==='/api/openlist/list' && req.method==='POST'){respond(res,200,{success:true,...await cloud.list(username,body)});return true;}
    if(route==='/api/openlist/play' && req.method==='POST'){
      const owner=body.owner || username, roomId=deps.binding(username)?.roomId;
      const ref={...body,owner,path:cloud.normalizePath(body.path)};
      if(!global.lx.config.users.some(u=>u.name===owner))throw Object.assign(new Error('分享账号已不存在'),{status:403});
      if(owner!==username && (!roomId || deps.binding(owner)?.roomId!==roomId || !granted(deps.room(roomId),ref)) && !await social.hasMediaGrant(username,ref,deps.listManage))throw Object.assign(new Error('该音乐尚未由所属账号分享到房间或保存的歌单'),{status:403});
      const item=cloud.connection(owner,body.id),target=cloud.allowedPath(item,body.path);
      const ticket=crypto.randomBytes(24).toString('hex');
      tickets.set(ticket,{owner,viewer:username,roomId,id:body.id,path:target,password:String(body.password || ''),expiresAt:Date.now()+2*60*60*1000});
      respond(res,200,{success:true,url:'/api/openlist/stream?ticket='+ticket});return true;
    }
    if(route==='/api/openlist/transfer' && req.method==='POST'){
      const resolved=await deps.resolve(body.song,body.quality || 'flac',username);
      const extension=/\.(flac|m4a|aac|ogg|wav|mp3)(?:[?#]|$)/i.exec(resolved.url)?.[1] || (String(resolved.quality).includes('flac')?'flac':'mp3');
      const input=await transport.open(resolved.url,{headers:{'Accept-Encoding':'identity'},signal:abort.signal,category:'music'});
      if(input.statusCode!==200){input.destroy();throw new Error(`音乐源返回 ${input.statusCode}`);}
      try {
        const result=await cloud.put(username,{id:body.id,path:body.path,filename:body.filename || `${body.song.singer || '未知歌手'} - ${body.song.name}.${extension}`},input,input.headers['content-length'],input.headers['content-type'],abort.signal);
        respond(res,200,{success:true,...result,quality:resolved.quality});
      } finally {input.destroy();}
      return true;
    }
    if(route==='/api/media/download' && req.method==='POST'){
      await require('./mediaExports').serve(req,res,{song:body.song,quality:body.quality,parts:['song'],owner:username,signal:abort.signal},exportDeps);return true;
    }
    if(route==='/api/user/subscriptions/sync' && req.method==='POST'){
      if(body.listId!==undefined && (typeof body.listId!=='string' || !body.listId || body.listId.length>240))throw new Error('歌单标识无效');
      const result=await serial(username,()=>require('./playlistSync').syncAccount(username,deps,{listId:body.listId,signal:abort.signal}));respond(res,200,{success:true,...result});return true;
    }
    if(route==='/api/user/subscriptions' && req.method==='GET'){
      const result=await serial(username,()=>social.refreshSubscriptions(username,deps.listManage));respond(res,200,{success:true,...result});return true;
    }
    if(route==='/api/user/subscriptions/remove' && req.method==='POST'){
      social.unsubscribe(username,String(body.listId));respond(res,200,{success:true});return true;
    }
    const binding=deps.binding(username),room=binding && deps.room(binding.roomId);
    if(!room)throw Object.assign(new Error('请先加入听歌房间'),{status:403});
    const historyId=room.id+':'+room.createdAt;
    let result;
    if(route==='/api/room/chat' && req.method==='GET')result=social.history(historyId);
    else if(route==='/api/room/chat' && req.method==='POST')result=social.send(historyId,username,body.text);
    else if(route==='/api/room/chat/delete' && req.method==='POST')result=social.remove(historyId,body);
    else if(route==='/api/room/playlist/share' && req.method==='POST'){
      let playlist,listId=body.listId || null;
      if(listId){const data=await deps.listManage(username).getListData();playlist=listId==='love'?{name:'我的收藏',list:data.loveList}:listId==='default'?{name:'默认列表',list:data.defaultList}:data.userList.find(x=>x.id===listId);}
      else playlist={name:String(body.title || '分享音乐'),list:body.songs};
      if(!playlist)throw new Error('歌单不存在');await require('./musicShares').validateSongs(username,playlist.list,deps);
      playlist={...playlist,list:playlist.list.map(song=>song.openlist?{...song,openlist:{...song.openlist,owner:song.openlist.owner || username}}:song)};
      if(deps.binding(username)?.roomId!==room.id)throw new Error('房间已切换，请重新分享');
      for(const song of playlist.list)if(song.openlist)(room.cloudGrants ||= new Set()).add(cloudKey(song.openlist));deps.persist?.();
      result=social.addShare(historyId,username,listId,playlist,!listId && playlist.list.length===1?'song':'playlist');
    }else if(route==='/api/room/playlist/content' && req.method==='POST'){
      const share=social.getShare(historyId,String(body.shareId));respond(res,200,{success:true,playlist:share.snapshot});return true;
    }else if(route==='/api/room/playlist/save' && req.method==='POST'){
      const share=social.getShare(historyId,String(body.shareId));
      if(!['copy','subscribe','append'].includes(body.mode))throw new Error('选择保存副本或订阅');
      const saved=await serial(username,async()=>{
        const manage=deps.listManage(username),data=await manage.getListData();
        let snapshot=share.snapshot;
        if(body.mode==='subscribe'){
          if(!share.listId)throw new Error('临时分享不支持订阅，可保存到自己的歌单');
          const source=await deps.listManage(share.owner).getListData();
          const live=share.listId==='love'?{name:'我的收藏',list:source.loveList}:share.listId==='default'?{name:'默认列表',list:source.defaultList}:source.userList.find(x=>x.id===share.listId);
          if(!live)throw new Error('原歌单已删除');snapshot=social.cleanPlaylist(live);
        }
        await require('./musicShares').validateSongs(share.owner,snapshot.list,deps);
        if(deps.binding(username)?.roomId!==room.id)throw new Error('房间已切换');
        if(body.mode==='append'){
          const id=String(body.listId || ''),target=id==='default'?{id,name:'默认列表',list:data.defaultList}:id==='love'?{id,name:'我的收藏',list:data.loveList}:data.userList.find(l=>l.id===id);if(!target)throw new Error('要添加的歌单不存在');
          const songs=[...target.list];for(const song of snapshot.list)if(!songs.some(s=>song.openlist?s.openlist?.owner===song.openlist.owner && s.openlist?.id===song.openlist.id && s.openlist?.path===song.openlist.path:s.id===song.id && s.source===song.source))songs.push(song);
          manage.listDataManage.setMusicList(id,songs);await manage.createSnapshot();social.recordMediaGrants(username,id,share.owner,snapshot,true);return {list:{...target,list:songs},data:await manage.getListData()};
        }
        const id='room_'+crypto.randomUUID();
        const list={id,name:snapshot.name,Album:snapshot.cover,source:'webplayer',list:snapshot.list,locationUpdateTime:Date.now(),...(body.mode==='subscribe'?{subscription:{type:'room',owner:share.owner}}:{})};
        const {list:songs,...info}=list;
        manage.listDataManage.userLists.push(info);manage.listDataManage.setMusicList(id,songs);await manage.createSnapshot();
        social.recordMediaGrants(username,id,share.owner,list);
        if(body.mode==='subscribe')social.subscribe(username,id,share,room.id,body.shareId);
        return {list,data:await manage.getListData()};
      });respond(res,200,{success:true,...saved});return true;
    }else throw Object.assign(new Error('接口不存在或请求方式不正确'),{status:404});
    if(req.method==='POST')deps.broadcast(room,'room:chat-update',{
      revision:result.revision,
      ...(route.endsWith('/delete')?{deletedIds:body.ids || [],clear:body.all===true}:{message:result.messages.at(-1)})
    });
    respond(res,200,{success:true,...result});
  } catch(error){
    if(res.headersSent){res.destroy(error);}else respond(res,error.status || 400,{success:false,message:error.message || '操作失败'});
  }
  return true;
}
module.exports={handle,serial,authorizeRoomMedia,startSubscriptionSync};
