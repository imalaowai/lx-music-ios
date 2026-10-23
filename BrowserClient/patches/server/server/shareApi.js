'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {pipeline}=require('node:stream/promises');
const shares=require('./musicShares'),transport=require('./mediaTransport'),cloud=require('./openList'),social=require('./roomSocial');
const sessions=new Map(),attempts=new Map(),streams=new Map(),resolutions=new Map();
const cookieName=id=>'lx_share_'+id;
const fail=(message,status=400)=>Object.assign(new Error(message),{status});
function json(res,status,data){if(res.headersSent)return;res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer'});res.end(JSON.stringify(data));}
async function body(req){let length=0;const chunks=[];for await(const chunk of req){length+=chunk.length;if(length>5*1024*1024)throw fail('内容过大',413);chunks.push(chunk);}try{return JSON.parse(Buffer.concat(chunks).toString() || '{}');}catch{throw fail('请求内容无效');}}
function authorized(req,item){if(!item.password)return true;const cookies=Object.fromEntries(String(req.headers.cookie || '').split(';').map(x=>x.trim().split('=')));const session=sessions.get(cookies[cookieName(item.id)]);return session?.id===item.id && session.revision===item.revision && session.until>Date.now();}
function issue(req,res,item){const token=crypto.randomBytes(32).toString('hex'),until=Math.min(Date.now()+86400000,item.expiresAt || Infinity);if(sessions.size>=10000)sessions.delete(sessions.keys().next().value);sessions.set(token,{id:item.id,revision:item.revision,until});res.setHeader('Set-Cookie',`${cookieName(item.id)}=${token}; Path=/api/shares/public/${item.id}/; HttpOnly; SameSite=Lax; Max-Age=${Math.floor((until-Date.now())/1000)}${req.socket.encrypted || req.headers['x-forwarded-proto']==='https'?'; Secure':''}`);}
function stop(id){for(const controller of streams.get(id) || [])controller.abort();for(const key of resolutions.keys())if(key.startsWith(id+':'))resolutions.delete(key);}
setInterval(()=>{for(const [key,s]of sessions)if(s.until<Date.now())sessions.delete(key);for(const [key,s]of attempts)if(s.until<Date.now())attempts.delete(key);for(const [key,s]of resolutions)if(s.until<Date.now())resolutions.delete(key);},60000).unref();
async function bounded(task,ms=12000){let timer;try{return await Promise.race([task,new Promise((_,reject)=>{timer=setTimeout(()=>reject(fail('媒体读取超时',502)),ms);timer.unref();})]);}finally{clearTimeout(timer);}}
async function resolve(item,track,deps,quality){
  const key=item.id+':'+track.key+':'+quality,old=resolutions.get(key);if(old && old.until>Date.now())return old.promise;
  const promise=(async()=>{const song=track.song;
    if(song.openlist){await shares.validateSongs(item.owner,[song],deps);return (await cloud.file(song.openlist.owner || item.owner,song.openlist)).url;}
    return (await deps.resolve(song,quality,item.owner)).url;
  })();resolutions.set(key,{promise,until:Date.now()+60000});promise.catch(()=>resolutions.delete(key));return bounded(promise);
}
async function media(item,track,kind,req,res,deps){
  const controller=new AbortController(),set=streams.get(item.id) || new Set();streams.set(item.id,set);set.add(controller);
  let expiryTimer;const expire=()=>{const remaining=item.expiresAt-Date.now();if(remaining<=0)controller.abort();else{expiryTimer=setTimeout(expire,Math.min(remaining,2147483647));expiryTimer.unref();}};if(item.expiresAt)expire();
  const closed=()=>{if(!res.writableFinished)controller.abort();};req.once('aborted',closed);res.once('close',closed);
  try{
    let source;
    if(kind==='cover'){
      const s=track.song;source=s.meta?.picUrl || s.img || s.pic || s.picUrl;
      if(!source || /logo\.svg|^blob:|^data:/.test(source))source=await bounded(deps.cover(s));
      if(!source || !/^https?:\/\//i.test(source))throw fail('暂无封面',404);
    }else {const value=new URL(req.url,'http://localhost').searchParams.get('quality');source=await resolve(item,track,deps,['128k','320k'].includes(value)?value:'flac');}
    const active=shares.get(item.id);if(active.revision!==item.revision || !authorized(req,active))throw fail('分享权限已更新',401);
    if(kind!=='cover'){
      await require('./mediaPlayback').serve(source,req,res,{signal:controller.signal,downloadName:kind==='download'?(track.song.name || '音乐'):undefined,validate:()=>{const current=shares.get(item.id);if(current.revision!==item.revision || !authorized(req,current))throw fail('分享权限已更新',401);}});return;
    }
    const upstream=await transport.open(source,{method:req.method==='HEAD'?'HEAD':'GET',headers:{...(req.headers.range?{Range:req.headers.range}:{}),'Accept-Encoding':'identity'},signal:controller.signal,category:'music'});
    const type=String(upstream.headers['content-type'] || '').split(';')[0];
    if(upstream.statusCode===416){res.writeHead(416,{'Content-Range':upstream.headers['content-range'] || 'bytes */*','Cache-Control':'no-store'});upstream.destroy();res.end();return;}
    if(![200,206].includes(upstream.statusCode) || (kind==='cover'?!/^image\/(jpeg|png|gif|webp|avif)$/.test(type):type && !/^audio\//.test(type) && !['application/octet-stream','binary/octet-stream','video/mp4','application/ogg'].includes(type))){upstream.destroy();throw fail('媒体不可用',502);}
    const headers={'Content-Type':kind==='cover'?type:/^audio\//.test(type)?type:'application/octet-stream','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer',...Object.fromEntries(['content-length','content-range','accept-ranges'].filter(k=>upstream.headers[k]).map(k=>[k,upstream.headers[k]]))};
    if(kind==='download')headers['Content-Disposition']="attachment; filename*=UTF-8''"+encodeURIComponent((track.song.name || '音乐').replace(/[\r\n/\\]/g,'_')+(type.includes('flac')?'.flac':type.includes('wav')?'.wav':type.includes('mp4')?'.m4a':'.mp3'));
    res.writeHead(upstream.statusCode,headers);if(req.method==='HEAD'){upstream.destroy();res.end();}else await pipeline(upstream,res,{signal:controller.signal});
  }finally{clearTimeout(expiryTimer);set.delete(controller);if(!set.size)streams.delete(item.id);req.off('aborted',closed);res.off('close',closed);}
}
function staticFile(req,res,file,type){res.writeHead(200,{'Content-Type':type,'Cache-Control':'no-cache','X-Content-Type-Options':'nosniff','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'; base-uri 'self'; frame-ancestors 'none'"});if(req.method==='HEAD')res.end();else fs.createReadStream(file).pipe(res);}
async function handle(req,res,url,deps){
  const route=url.pathname;
  if(!route.startsWith('/api/shares/') && !route.startsWith('/share/') && route!=='/api/user/playlist-art')return false;
  const pub=/^\/api\/shares\/public\/([a-f0-9]{48})\/(info|unlock|data|audio|download|cover|options|export|batch)(?:\/([a-f0-9]{24}))?$/.exec(route);
  try{
    if(route.startsWith('/share/assets/')){
      const files={'browser-downloads.js':['js/browser_downloads.js','application/javascript'],'queue-audio.js':['js/queue_audio.js','application/javascript'],'download-options.js':['js/download_options.js','application/javascript'],'player.js':['share-player.js','application/javascript'],'player.css':['share-player.css','text/css'],'pwa.js':['js/pwa.js','application/javascript'],'sw.js':['share-sw.js','application/javascript'],'icon-192.png':['assets/icons/icon-192.png','image/png'],'icon-512.png':['assets/icons/icon-512.png','image/png'],'apple-touch-icon.png':['assets/icons/apple-touch-icon.png','image/png']};
      const spec=files[route.slice('/share/assets/'.length)];if(!spec || !['GET','HEAD'].includes(req.method))throw fail('不存在',404);if(route.endsWith('/sw.js'))res.setHeader('Service-Worker-Allowed','/share/');staticFile(req,res,path.join(global.lx.staticPath,'music',spec[0]),spec[1]);return true;
    }
    const page=/^\/share\/music\/([a-f0-9]{48})(\/|\/manifest\.webmanifest)?$/.exec(route);
    if(page){
      if(!['GET','HEAD'].includes(req.method))throw fail('请求方式不正确',405);
      if(!page[2]){res.writeHead(302,{'Location':route+'/','Cache-Control':'no-store'});res.end();return true;}
      if(page[2]==='/manifest.webmanifest'){
        const item=shares.get(page[1]);json(res,200,{id:`/share/music/${item.id}/`,name:item.title,short_name:item.title.slice(0,18),start_url:`/share/music/${item.id}/`,scope:`/share/music/${item.id}/`,display:'standalone',background_color:'#f5f5f7',theme_color:'#f5f5f7',icons:[{src:'/share/assets/icon-192.png',sizes:'192x192',type:'image/png'},{src:'/share/assets/icon-512.png',sizes:'512x512',type:'image/png',purpose:'any maskable'}]});return true;
      }
      staticFile(req,res,path.join(global.lx.staticPath,'music/share-player.html'),'text/html; charset=utf-8');return true;
    }
    if(pub){
      const [,id,action,key]=pub,item=shares.get(id);
      if(action==='info' && req.method==='GET'){json(res,200,{success:true,title:item.title,count:item.count,locked:!authorized(req,item)});return true;}
      if(action==='unlock' && req.method==='POST'){
        const input=await body(req),ip=global.lx.config['proxy.enabled']?req.headers[global.lx.config['proxy.header'] || 'x-real-ip'] || req.socket.remoteAddress:req.socket.remoteAddress;
        const rateKey=id+':'+ip,rate=attempts.get(rateKey) || {count:0,until:Date.now()+10*60000};if(rate.until<Date.now()){rate.count=0;rate.until=Date.now()+10*60000;}if(rate.count>=10)throw fail('尝试次数过多，请稍后再试',429);
        rate.count++;attempts.set(rateKey,rate);if(!await shares.matches(item,input.password)){throw fail('分享密码错误',401);}attempts.delete(rateKey);issue(req,res,item);json(res,200,{success:true});return true;
      }
      if(!authorized(req,item))throw fail('请输入分享密码',401);
      if(action==='data' && req.method==='GET'){json(res,200,{success:true,...shares.publicData(item)});return true;}
      if(action==='batch' && req.method==='GET'){
        if(!item.allowDownload)throw fail('分享者未允许下载',403);const snapshot=shares.content(id),controller=new AbortController(),set=streams.get(item.id) || new Set();streams.set(item.id,set);set.add(controller);
        try{await require('./mediaExports').serveBatch(req,res,{songs:snapshot.tracks.map(t=>t.song),owner:item.owner,title:item.title,quality:url.searchParams.get('quality') || 'flac',parts:url.searchParams.get('parts') || 'song',signal:controller.signal,expiresAt:item.expiresAt},{...deps,authorize:song=>shares.validateSongs(item.owner,[song],deps)});}finally{set.delete(controller);if(!set.size)streams.delete(item.id);}return true;
      }
      if(['options','export'].includes(action) && req.method==='GET'){
        if(!item.allowDownload)throw fail('分享者未允许下载',403);const track=shares.content(id).tracks.find(s=>s.key===key);if(!track)throw fail('音乐不存在',404);
        const exportDeps={...deps,authorize:()=>shares.validateSongs(item.owner,[track.song],deps)};
        if(action==='options')json(res,200,{success:true,...await require('./mediaExports').options(track.song,item.owner,exportDeps)});
        else{const controller=new AbortController(),set=streams.get(item.id) || new Set();streams.set(item.id,set);set.add(controller);try{await require('./mediaExports').serve(req,res,{song:track.song,owner:item.owner,quality:url.searchParams.get('quality') || 'flac',parts:url.searchParams.get('parts') || 'song',signal:controller.signal,expiresAt:item.expiresAt},exportDeps);}finally{set.delete(controller);if(!set.size)streams.delete(item.id);}}return true;
      }
      if(['audio','download','cover'].includes(action) && ['GET','HEAD'].includes(req.method)){
        const snapshot=shares.content(id);let track=snapshot.tracks.find(s=>s.key===key);if(action==='cover' && !key){track=snapshot.tracks[0];if(snapshot.cover)track={song:{...track.song,img:snapshot.cover,meta:{...track.song.meta,picUrl:snapshot.cover}}};}if(!track)throw fail('音乐不存在',404);if(action==='download' && !item.allowDownload)throw fail('分享者未允许下载',403);
        await media(item,track,action,req,res,deps);return true;
      }
      throw fail('接口不存在',404);
    }
    const username=deps.verify(req);if(!username || !global.lx.config.users.some(u=>u.name===username))throw fail('请先登录账号',401);
    if(route==='/api/user/playlist-art' && req.method==='POST'){
      const input=await body(req),list=await shares.playlist(username,input,deps);let cover=shares.rawCover(list);
      if(input.refresh || !cover || /logo\.svg|^blob:|^data:/.test(cover))cover=await bounded(deps.playlistCover(list));json(res,200,{success:true,cover:cover || ''});return true;
    }
    if(route==='/api/shares/manage' && req.method==='GET'){json(res,200,{success:true,shares:shares.list(username)});return true;}
    if(route==='/api/shares/manage' && req.method==='POST'){json(res,200,{success:true,share:await shares.create(username,await body(req),deps)});return true;}
    const edit=/^\/api\/shares\/manage\/([a-f0-9]{48})(\/room)?$/.exec(route);
    if(edit && req.method==='POST'){
      const item=shares.get(edit[1],true);if(item.owner!==username)throw fail('分享不存在',404);
      if(edit[2]){
        shares.get(item.id);const binding=deps.binding(username),room=binding && deps.room(binding.roomId);if(!room)throw fail('请先加入听歌房间',403);
        const snapshot=shares.content(item.id),songs=snapshot.tracks.map(t=>t.song);await shares.validateSongs(username,songs,deps);if(deps.binding(username)?.roomId!==room.id)throw fail('房间已切换');for(const song of songs)if(song.openlist)(room.cloudGrants ||= new Set()).add(JSON.stringify([song.openlist.owner || username,song.openlist.id,cloud.normalizePath(song.openlist.path)]));deps.persist?.();const history=social.addShare(room.id+':'+room.createdAt,username,null,{name:item.title,cover:snapshot.cover,list:songs},songs.length===1?'song':'playlist');deps.broadcast(room,'room:chat-update',{revision:history.revision,message:history.messages.at(-1)});json(res,200,{success:true,...history});return true;
      }
      const result=await shares.update(username,item.id,await body(req));if(result.revision!==item.revision)stop(item.id);json(res,200,{success:true,share:result});return true;
    }
    throw fail('接口不存在',404);
  }catch(error){if(res.headersSent)res.destroy();else{const status=error.status || 400;json(res,status,{success:false,message:pub && ![401,403,404,410,429].includes(status)?'这首音乐暂时无法播放，请重试或切换歌曲':error.message});}}
  return true;
}
module.exports={handle};
