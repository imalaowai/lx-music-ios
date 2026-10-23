'use strict';
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium,webkit,devices}=require(process.env.LX_PLAYWRIGHT || 'playwright');
const root=path.resolve(__dirname,'..'),out=root+'/build/review';fs.mkdirSync(out,{recursive:true});
let html=fs.readFileSync(root+'/../NativeCompanion/generated/WebUI.html','utf8');
for(const name of ['account-panel.js','device_library.js','download_options.js','download_manager.js']){
 const pattern=new RegExp('(<script\\b[^>]*data-source="js/'+name.replaceAll('.','\\.')+'\\?[^"\\n]*"[^>]*>).*?(</script>)','s');
 assert.ok(pattern.test(html),name);html=html.replace(pattern,(_,a,b)=>a+fs.readFileSync(root+'/js/'+name,'utf8')+b);
}
html=html.replace('</head>','<link rel="stylesheet" href="/css/qiye.css"><link rel="stylesheet" href="/css/qiye_browser.css"></head>');
html=html.replace('</body>',['browser_downloads','qiye_offline','qiye_browser','qiye_shell','qiye_header'].map(n=>'<script src="/js/'+n+'.js"></script>').join('')+'</body>');
const audio=Buffer.concat([Buffer.from('ID3'),Buffer.alloc(2048,17)]),song={id:'wy_fixture',songmid:'fixture',source:'wy',name:'下载测试',singer:'栖页'};
let exportRequests=[];
const watchdog=setTimeout(()=>{console.error('Browser review exceeded 3 minutes');process.exit(1);},180000);watchdog.unref();
const server=http.createServer(async(req,res)=>{
 const url=new URL(req.url,'http://localhost');
 if(url.pathname==='/'){res.setHeader('Content-Type','text/html');res.end(html);return;}
 if(/^\/share\/music\/[a-f0-9]{48}\/$/.test(url.pathname)){res.setHeader('Content-Type','text/html');res.setHeader('Content-Security-Policy',"default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self'");res.end(fs.readFileSync(root+'/share-player.html'));return;}
 const aliases={'/share/assets/browser-downloads.js':'js/browser_downloads.js','/share/assets/download-options.js':'js/download_options.js','/share/assets/player.js':'share-player.js','/share/assets/player.css':'share-player.css'};
 if(aliases[url.pathname]){const name=aliases[url.pathname];res.setHeader('Content-Type',name.endsWith('.css')?'text/css':'application/javascript');res.end(fs.readFileSync(root+'/'+name));return;}
 if(['/share/assets/pwa.js','/share/assets/queue-audio.js'].includes(url.pathname)){res.setHeader('Content-Type','application/javascript');res.end('');return;}
 const local=path.resolve(root,'.'+url.pathname);
 if(local.startsWith(root+'/') && fs.existsSync(local) && fs.statSync(local).isFile()){
  res.setHeader('Content-Type',local.endsWith('.js')?'application/javascript':local.endsWith('.css')?'text/css':'text/html');res.end(fs.readFileSync(local));return;
 }
 const body=[];for await(const c of req)body.push(c);let data={};try{data=JSON.parse(Buffer.concat(body))}catch{}
 if(url.pathname==='/api/media/export'){
  exportRequests.push(data);if(data.song?.id==='bad'){res.writeHead(502,{'Content-Type':'application/json'});res.end('{"message":"音源返回的不是音频文件"}');return;}
  res.writeHead(200,{'Content-Type':'audio/mpeg','Content-Length':audio.length,'X-LX-Filename':encodeURIComponent('栖页 - 下载测试.mp3')});res.end(audio);return;
 }
 res.setHeader('Content-Type','application/json');
 if(url.pathname==='/api/media/options'){res.end(JSON.stringify({qualities:['flac24bit','flac','320k','128k'].map(quality=>({quality,available:true,actualQuality:'128k',format:'MP3',extension:'mp3'}))}));return;}
 if(url.pathname.endsWith('/options/track')){res.end(JSON.stringify({qualities:[{quality:'128k',available:true,actualQuality:'128k',format:'MP3',extension:'mp3'}]}));return;}
 if(url.pathname.endsWith('/export/track')){res.writeHead(200,{'Content-Type':'audio/mpeg','Content-Length':audio.length,'Content-Disposition':"attachment; filename*=UTF-8''"+encodeURIComponent('分享歌曲.mp3')});res.end(audio);return;}
 if(url.pathname.endsWith('/info')){res.end(JSON.stringify({title:'测试分享',count:1,locked:false}));return;}
 if(url.pathname.endsWith('/data')){res.end(JSON.stringify({title:'测试分享',count:1,allowDownload:true,tracks:[{id:'track',name:'分享歌曲',singer:'栖页',cover:'',audio:'/audio'}]}));return;}
 if(url.pathname.includes('/songList/list')){res.end(JSON.stringify({list:[{id:'mix',name:'精选歌单',source:'wy'}]}));return;}
 if(url.pathname.includes('/custom-source/list')){res.end('[]');return;}
 res.end(JSON.stringify(url.pathname.includes('/music/config')?{'player.enableAuth':false}:url.pathname.includes('/room/binding')?{binding:null}:url.pathname.includes('/room/chat')?{messages:[]}:{success:true,data:{defaultList:[],loveList:[],userList:[]},list:[],tasks:[],enabled:false}));
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port,report=[];
 try{for(const [engine,name]of [[chromium,'chromium'],[webkit,'webkit']]){
 const browser=await engine.launch({headless:true,args:name==='chromium'?['--no-sandbox','--disable-dev-shm-usage']:[]});
 try{for(const width of [1440,430,375]){
 console.log('Web review '+name+' '+width);const context=await browser.newContext({...width<700?devices['iPhone 13 Pro Max']:{},viewport:{width,height:width<700?800:950},serviceWorkers:'block',acceptDownloads:true});
 await context.addInitScript(()=>{localStorage.setItem('lx_desktop_layout','apple');localStorage.setItem('lx_sync_mode','local');localStorage.setItem('lx_settings',JSON.stringify({autoResume:false,keepScreenAwake:false}));});
 const page=await context.newPage(),errors=[];page.setDefaultTimeout(12000);page.on('pageerror',e=>errors.push(e.message));await page.route('https://**/*',r=>r.abort());
 try{
 await page.goto(base,{waitUntil:'load'});await page.waitForFunction(()=>window.NativeShell && document.getElementById('qiye-page-header'));
 await page.waitForTimeout(200);console.log(name,width,'page ready');
 const geometry=await page.evaluate(()=>{
  const box=id=>{const r=document.getElementById(id).getBoundingClientRect();return {top:r.top,bottom:r.bottom,left:r.left,right:r.right,height:r.height};};
  return {header:box('qiye-page-header'),account:box('qiye-account'),home:box('view-native-home'),position:getComputedStyle(document.getElementById('qiye-account')).position,accountParent:document.getElementById('qiye-account').parentElement.id};
 });
 assert.equal(geometry.position,'relative');assert.equal(geometry.accountParent,'qiye-header-account-slot');assert.ok(geometry.account.top>=geometry.header.top && geometry.account.bottom<=geometry.header.bottom);assert.ok(geometry.home.top>=geometry.header.bottom-1,'header reserves page space');
 await page.evaluate(()=>{const detail={binding:{roomId:'123456'},connected:true,participantId:'me',state:{controllerId:'me'},participants:[{id:'me',name:'我',avatar:{type:'emoji',value:'🎧'}},{id:'friend',name:'朋友',avatar:{type:'emoji',value:'🌻'}},{id:'third',name:'小林'},{id:'fourth',name:'小夏'}]};window.NativeShell.state.room=detail;window.dispatchEvent(new CustomEvent('lx-native-room',{detail}));window.dispatchEvent(new CustomEvent('lx-room-unread',{detail:{count:3}}));});
 assert.equal(await page.locator('#qiye-header-unread').textContent(),'3');assert.equal(await page.locator('#qiye-header-members .qiye-room-avatar').count(),4);assert.ok(await page.locator('#qiye-header-members').isVisible());
 await page.screenshot({path:out+'/'+name+'-'+width+'-home.png'});
 console.log(name,width,'header checked');await page.locator('#qiye-header-room').click();assert.ok(await page.locator('#view-native-room').isVisible());const roomTop=await page.locator('#view-native-room').boundingBox(),head=await page.locator('#qiye-page-header').boundingBox();assert.ok(roomTop.y>=head.y+head.height-1);
 await page.locator('#qiye-header-members').click();await page.getByRole('button',{name:'关闭',exact:true}).last().click();
 await page.evaluate(()=>window.NativeShell.go('home'));
 console.log(name,width,'room checked');
 // The real public download entry must reach the quality selector and fetch.
 await page.evaluate(song=>{window.DeviceLibrary.downloadBatch([song]).catch(e=>window.__downloadError=e.message);},song);
 await page.locator('.lx-prompt-modal button[data-value="下载到手机 / 电脑"]').click();await page.waitForSelector('.download-options-overlay select');
 await page.locator('.download-options-overlay select').selectOption('128k');
 await page.locator('.download-options-overlay input[name=lyrics]').uncheck();await page.locator('.download-options-overlay input[name=cover]').uncheck();
 await page.getByRole('button',{name:'开始下载',exact:true}).click();
 console.log(name,width,'submitted download');const save=page.locator('#browser-download-panel a[download]');await save.waitFor();assert.equal(await save.getAttribute('download'),'栖页 - 下载测试.mp3');assert.deepEqual(exportRequests.at(-1).parts,['song']);assert.equal(exportRequests.at(-1).quality,'128k');
 const downloadEvent=page.waitForEvent('download');await save.click();const download=await downloadEvent;const downloaded=await download.path();assert.deepEqual(fs.readFileSync(downloaded),audio);
 await page.screenshot({path:out+'/'+name+'-'+width+'-download.png'});await page.locator('[data-download-close]').click();
 await page.evaluate(song=>{window.BrowserDownloads.songs([{...song,id:'bad'}],{quality:'128k',parts:['song']});},song);await page.locator('[data-download-status]').filter({hasText:'不是音频'}).waitFor();assert.equal(await page.locator('#browser-download-panel a[download]').count(),0);await page.locator('[data-download-close]').click();
 // A slow probe cannot lock out manual quality selection or lyrics-only saves.
 await page.evaluate(()=>{window.DownloadOptions.choose({probe:()=>new Promise(()=>{})}).then(value=>window.__slowChoice=value);});
 assert.equal(await page.locator('.download-options-overlay select').isEnabled(),true);await page.locator('.download-options-overlay select').selectOption('320k');await page.locator('.download-options-overlay input[name=song]').uncheck();await page.locator('.download-options-overlay input[name=cover]').uncheck();await page.getByRole('button',{name:'开始下载',exact:true}).click();assert.deepEqual(await page.evaluate(()=>window.__slowChoice),{quality:'320k',parts:['lyrics']});
 if(width===375){
  await page.goto(base+'/share/music/'+'a'.repeat(48)+'/',{waitUntil:'load'});await page.locator('.share-track-download').waitFor();await page.locator('.share-track-download').click();await page.locator('.download-options-overlay select').selectOption('128k');await page.locator('.download-options-overlay input[name=lyrics]').uncheck();await page.locator('.download-options-overlay input[name=cover]').uncheck();await page.getByRole('button',{name:'开始下载',exact:true}).click();const shareSave=page.locator('#browser-download-panel a[download]');await shareSave.waitFor();const event=page.waitForEvent('download');await shareSave.click();const file=await event;assert.deepEqual(fs.readFileSync(await file.path()),audio);assert.equal(await shareSave.getAttribute('download'),'分享歌曲.mp3');await page.screenshot({path:out+'/'+name+'-'+width+'-share-download.png'});
 }
 report.push({engine:name,width,headerInFlow:true,memberAvatars:true,unreadBadge:true,downloadExactBytes:true,badFileRejected:true,manualQuality:true,errors});assert.deepEqual(errors,[]);
 }catch(error){await page.screenshot({path:out+'/'+name+'-'+width+'-failure.png'});fs.writeFileSync(out+'/failure.json',JSON.stringify({error:error.stack,errors,diagnostic:await page.evaluate(()=>({downloadError:window.__downloadError,runtime:window.LXNative?.runtime,options:[...document.querySelectorAll('.lx-prompt-modal button')].map(n=>({text:n.textContent,value:n.dataset.value}))}))},null,2));throw error;}finally{await context.close();}
 }}finally{await browser.close();}
 }}finally{fs.writeFileSync(out+'/report.json',JSON.stringify(report,null,2));await new Promise(r=>server.close(r));}
})().catch(e=>{console.error(e);process.exitCode=1;});
