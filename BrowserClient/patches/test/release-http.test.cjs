'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),net=require('node:net'),crypto=require('node:crypto'),{spawn}=require('node:child_process');
const version=require('../package.json').version;
const {verifyHttp}=require('../scripts/verify-release.cjs'),root=process.env.LX_TEST_PROJECT || path.resolve(__dirname,'..');
test('Release verification checks real HTTP bytes with custom paths and authentication, and detects stale pages',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'lx-release-http-')),server=net.createServer();await new Promise(r=>server.listen(0,'127.0.0.1',r));const port=server.address().port;await new Promise(r=>server.close(r));
 const files={};for(const name of ['js/qiye_header.js','js/browser_downloads.js','js/download_options.js','css/utilities.css','js/qiye_browser.js','js/qiye_shell.js','js/qiye_offline.js','css/qiye.css','css/qiye_browser.css','qiye-ui.json','index.html','app.js','js/queue_audio.js','js/listen_room.js','js/room_start.js','js/ios-background-audio.js','js/sound-effects.js','js/release_guard.js','js/pwa_update.js','js/pwa.js','js/ios_audio_output.js','js/device_library.js','js/library_sync.js','js/account-panel.js','js/library_hub.js','pwa-repair.html','sw.js','release.json','lockscreen-check.html','js/lockscreen-check.js','assets/audio/check-low.mp3','assets/audio/check-mid.mp3','assets/audio/check-high.mp3'])files['public/music/'+name]={sha256:crypto.createHash('sha256').update(fs.readFileSync(root+'/public/music/'+name)).digest('hex')};
 fs.mkdirSync(dir+'/data');fs.writeFileSync(dir+'/data/config.js','module.exports='+JSON.stringify({port,users:[{name:'release-fixture',password:'fixture-private-account-password'}],disableTelemetry:true,'player.path':'/custom-player','player.enableAuth':true,'player.password':'fixture-player-password','webdav.enable':false,'subsonic.enable':false,'configBackup.enable':false,'proxy.app.enabled':false}));
 const log=fs.openSync(dir+'/server.log','w'),child=spawn(process.execPath,[root+'/index.js'],{cwd:dir,env:{...process.env,PORT:String(port),DATA_PATH:dir+'/data',CONFIG_PATH:dir+'/data/config.js',STATIC_PATH:root+'/public',LOG_PATH:dir+'/logs'},stdio:['ignore',log,log]});
 try{
  let ready=false;for(let i=0;i<120;i++){try{if((await fetch('http://127.0.0.1:'+port+'/api/music/config')).ok){ready=true;break;}}catch{}await new Promise(r=>setTimeout(r,30));}assert.ok(ready,'fixture server starts');
  const startupLog=fs.readFileSync(dir+'/server.log','utf8');assert.ok(startupLog.includes('release-fixture'));assert.equal(startupLog.includes('fixture-private-account-password'),false);assert.equal(startupLog.includes('fixture-player-password'),false);
  await verifyHttp(dir,{version,files});
  const url='http://127.0.0.1:'+port+'/custom-player/js/queue_audio.js',first=await fetch(url);assert.equal(first.headers.get('cache-control'),'no-store');
  const second=await fetch(url,{headers:{'If-None-Match':first.headers.get('etag'),'If-Modified-Since':first.headers.get('last-modified')}});assert.equal(second.status,200,'scripts cannot reuse weak mtime/size validators');
  const stale=structuredClone(files);stale['public/music/app.js'].sha256='0'.repeat(64);await assert.rejects(()=>verifyHttp(dir,{version,files:stale}),/HTTP content differs: music\/app.js/);
 }finally{const done=new Promise(r=>child.once('exit',r));child.kill();if(child.exitCode===null && child.signalCode===null)await done;fs.closeSync(log);fs.rmSync(dir,{recursive:true,force:true});}
});
