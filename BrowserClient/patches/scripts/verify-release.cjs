'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),http=require('node:http');
const entries=['server','public','scripts','test','node_modules','index.js','package.json','package-lock.json','LICENSE','NOTICE','upgrade.sh'];
const preserved=['server/data','server/cache','server/music','server/logs','server/downloads','public/uploads','public/music/uploads'];
const isPreserved=name=>preserved.some(prefix=>name===prefix || name.startsWith(prefix+'/'));
function digest(data){return crypto.createHash('sha256').update(data).digest('hex');}
function inventory(root){
 const files={};
 function walk(relative){
  const full=path.join(root,relative),s=fs.lstatSync(full);
  if(isPreserved(relative))return;
  if(s.isSymbolicLink()){const link=fs.readlinkSync(full);if(!path.resolve(path.dirname(full),link).startsWith(root+path.sep))throw Error('Link outside release: '+relative);files[relative]={link};}
  else if(s.isDirectory())for(const name of fs.readdirSync(full).sort())walk(relative+'/'+name);
  else if(s.isFile())files[relative]={sha256:digest(fs.readFileSync(full))};
  else throw Error('Unsupported release entry: '+relative);
 }
 for(const entry of entries)walk(entry);
 return files;
}
function verify(root,manifestRoot=root){
 root=path.resolve(root);const manifest=JSON.parse(fs.readFileSync(path.join(manifestRoot,'release-manifest.json'),'utf8'));
 if(JSON.stringify(manifest.entries)!==JSON.stringify(entries))throw Error('Invalid managed entries');
 const actual=inventory(root),expected=manifest.files,missing=[],changed=[],extra=[];
 for(const name of Object.keys(expected)){if(!actual[name])missing.push(name);else if(JSON.stringify(actual[name])!==JSON.stringify(expected[name]))changed.push(name);}
 for(const name of Object.keys(actual))if(!expected[name])extra.push(name);
 if(missing.length || changed.length || extra.length)throw Error(JSON.stringify({missing:missing.slice(0,10),changed:changed.slice(0,10),extra:extra.slice(0,10)}));
 if(JSON.parse(fs.readFileSync(path.join(root,'package.json'),'utf8')).version!==manifest.version)throw Error('Package version mismatch');
 return manifest;
}
function request(port,url,{method='GET',headers={},body}={}){return new Promise((resolve,reject)=>{const req=http.request({host:'127.0.0.1',port,path:url,method,headers:{'Cache-Control':'no-cache',...headers},timeout:3000},res=>{const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.on('error',reject);res.on('end',()=>res.statusCode===200?resolve({bytes:Buffer.concat(chunks),headers:res.headers}):reject(Error(url+' HTTP '+res.statusCode)));});req.on('error',reject);req.on('timeout',()=>req.destroy(Error('HTTP timeout')));req.end(body);});}
async function get(port,url,headers){return (await request(port,url,{headers})).bytes;}
async function verifyHttp(root,manifest){
 let config={};try{config=require(process.env.CONFIG_PATH || path.join(process.env.DATA_PATH || path.join(root,'data'),'config.js'));}catch{}
 const port=Number(process.env.PORT || config.port || 9527);
 const live=JSON.parse(await get(port,'/api/music/config'));let cookie='';
 if(live['player.enableAuth']){
  const password=process.env.WEBPLAYER_PASSWORD || config['player.password'] || require('../server/defaultConfig.js').default['player.password'];
  const auth=await request(port,'/api/music/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password})});
  if(!JSON.parse(auth.bytes).success)throw Error('Cannot authenticate local verification');
  cookie=(auth.headers['set-cookie'] || []).map(value=>value.split(';')[0]).join('; ');
 }
 const prefix=String(process.env.PLAYER_PATH ?? config['player.path'] ?? '/').replace(/\/+$/,'');
 const probe=['music/js/qiye_header.js','music/js/browser_downloads.js','music/js/download_options.js','music/css/utilities.css','music/js/qiye_browser.js','music/js/qiye_shell.js','music/js/qiye_offline.js','music/css/qiye.css','music/css/qiye_browser.css','music/qiye-ui.json','music/index.html','music/app.js','music/js/queue_audio.js','music/js/listen_room.js','music/js/room_start.js','music/js/ios-background-audio.js','music/js/sound-effects.js','music/js/release_guard.js','music/js/pwa_update.js','music/js/pwa.js','music/js/ios_audio_output.js','music/js/device_library.js','music/js/library_sync.js','music/js/account-panel.js','music/js/library_hub.js','music/pwa-repair.html','music/sw.js','music/release.json','music/lockscreen-check.html','music/js/lockscreen-check.js','music/assets/audio/check-low.mp3','music/assets/audio/check-mid.mp3','music/assets/audio/check-high.mp3'];
 try{
  for(const item of probe){const url=prefix+'/'+item.slice('music/'.length);const bytes=await get(port,url+'?release='+manifest.version,cookie?{Cookie:cookie}:{});if(digest(bytes)!==manifest.files['public/'+item]?.sha256)throw Error('HTTP content differs: '+item);}
  const configBytes=(await get(port,'/js/config.js')).toString();if(!configBytes.includes('v'+manifest.version))throw Error('Served config version differs');
 }finally{if(cookie)await request(port,'/api/music/auth/logout',{method:'POST',headers:{Cookie:cookie}});}
}
if(require.main===module){const [mode,rootArg]=process.argv.slice(2),root=path.resolve(rootArg || path.join(__dirname,'..'));(async()=>{if(mode==='--write'){fs.writeFileSync(path.join(root,'release-manifest.json'),JSON.stringify({version:require(path.join(root,'package.json')).version,entries,files:inventory(root)},null,2)+'\n');return;}const manifest=verify(root);if(mode==='--http')await verifyHttp(root,manifest);console.log('Verified v'+manifest.version+': '+Object.keys(manifest.files).length+' files'+(mode==='--http'?', HTTP player bytes match.':'.'));})().catch(error=>{console.error(error.message);process.exitCode=1;});}
module.exports={entries,inventory,verify,verifyHttp,isPreserved};
