// Integration review of the actual packaged page, including both browser engines.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium,webkit,devices}=require(process.env.LX_PLAYWRIGHT || 'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'build/ui-review');fs.mkdirSync(out,{recursive:true});
const html=fs.readFileSync(root+'/generated/WebUI.html'),bridge=fs.readFileSync(root+'/Resources/Bridge.js','utf8'),shell=fs.readFileSync(root+'/Resources/AppShell.js','utf8'),shellCSS=fs.readFileSync(root+'/Resources/AppShell.css','utf8');
const server=http.createServer((req,res)=>{
 if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end(html);return;}
 res.setHeader('Content-Type','application/json');
 if(req.url.startsWith('/api/custom-source/list')){res.end('[]');return;}
 res.end(JSON.stringify(req.url.includes('/api/music/config')?{'player.enableAuth':false}: {success:true,data:{defaultList:[],loveList:[],userList:[]},list:[],tasks:[],enabled:false}));
});
(async()=>{
 await new Promise(r=>server.listen(0,'127.0.0.1',r));const base='http://127.0.0.1:'+server.address().port,reports=[];
 const engines=process.env.LX_CHROMIUM?[[chromium,'chromium']]:[[chromium,'chromium'],[webkit,'webkit']];
 for(const [engine,name] of engines){
  const browser=await engine.launch({headless:true,...(process.env.LX_CHROMIUM?{executablePath:process.env.LX_CHROMIUM}:{}),args:name==='chromium'?['--no-sandbox','--no-zygote','--disable-dev-shm-usage']:[]});
  try{
   for(const width of (process.env.LX_TEST_WIDTH?[Number(process.env.LX_TEST_WIDTH)]:[1440,430,375])){
    const phone=width<700,context=await browser.newContext({...phone?devices['iPhone 13 Pro Max']:{},viewport:{width,height:phone?(width===375?667:932):950},serviceWorkers:'block'});
    await context.addInitScript(()=>{
     localStorage.setItem('lx_desktop_layout','apple');localStorage.setItem('lx_sync_mode','local');
     localStorage.setItem('lx_theme_profiles',JSON.stringify({apple:{colour:'rose'},kugou:{colour:'blue'}}));
     localStorage.setItem('lx_settings',JSON.stringify({autoResume:false,keepScreenAwake:false}));
     window.__nativeCommands=[];window.__mockAccount=false;
     window.__offlineSong={id:'offline-fixture',offlineId:'11111111-1111-4111-8111-111111111111',name:'离线音乐',singer:'本机歌手',source:'local',img:'lx-local://cover/11111111-1111-4111-8111-111111111111'};
     window.__mockRoom={binding:{roomId:'123456'},participantId:'me',connected:true,enabled:true,syncOnTrack:true,state:{controllerId:'me',paused:true},participants:[{id:'me',name:'alice',nickname:'我',avatar:{type:'emoji',value:'🎧'}},{id:'friend',name:'bob',nickname:'朋友',avatar:{type:'emoji',value:'🌻'}}]};
     window.__chatMessages=[{id:'m1',kind:'text',text:'一起听音乐吧',time:Date.now()-10000,author:{name:'bob',nickname:'朋友'}}];
     window.webkit={messageHandlers:{lxNative:{postMessage(message){
      window.__nativeCommands.push(message);
      queueMicrotask(()=>{
       let value=true;
       if(message.op==='appInfo')value={version:'1.2.0',server:window.__mockAccount?location.origin:'',username:window.__mockAccount?'alice':'',hasAccount:window.__mockAccount,bundledUI:true,legacySourceFallback:true};
       if(message.op==='downloads')value=[{id:window.__offlineSong.offlineId,song:window.__offlineSong,status:'finished',hasCover:true,hasLyric:true,quality:'local'}];
       if(message.op==='downloadAssets')value={lyric:'[00:00.00]离线歌词测试\n[00:15.00]无需服务器'};
       if(message.op==='sources'||message.op==='serverSources')value=[];
       if(message.op==='musicApi'){
        if(message.path.includes('/config'))value={'player.enableAuth':false};
        else if(message.path.includes('/songList/list'))value={list:Array.from({length:4},(_,i)=>({id:'recommend-'+i,name:['今天听点什么','城市漫游','温柔的夜色','清晨的旋律'][i],source:'wy',author:'音乐推荐'}))};
        else if(message.path.includes('/hotSearch'))value=['周杰伦','晴天','流行新歌','一路向北'];
        else if(message.path.includes('/lyric'))value={lyric:'[00:00.00]测试歌词'};
        else value=[];
       }
       if(message.op==='musicApi'&&message.path.includes('/hotSearch')&&!window.__hotReleased){(window.__pendingHot||=[]).push(()=>window.LXBridge.reply(message.id,value,null));window.__releaseHot=()=>{window.__hotReleased=true;for(const resolve of window.__pendingHot.splice(0))resolve();};return;}
       if(message.op==='musicApi'&&message.path.includes('/songList/list')&&window.__catalogFail&&message.path.includes('sortId=new')){window.LXBridge.reply(message.id,false,'Fixture primary provider failure');return;}
       window.LXBridge.reply(message.id,value,null);
       if(message.op==='roomMembership')window.LXBridge.room(message.operation==='leave'?{binding:null,participants:[],state:{},connected:false}:window.__mockRoom);
       if(message.op==='roomRefresh')window.LXBridge.room(window.__mockRoom);
       if(message.op==='select')window.LXBridge.state({queueRevision:10,queue:message.queue,index:message.index,song:message.queue[message.index],paused:false,playing:true,position:12,duration:180,mode:'list'});
      });
     }}}};
    });
    await context.addInitScript({content:bridge});
    await context.addInitScript({content:'window.__LX_SHELL_CSS__='+JSON.stringify(shellCSS)+';document.addEventListener("DOMContentLoaded",()=>{'+shell+'});'});
    const page=await context.newPage(),errors=[],remoteUI=[];page.setDefaultTimeout(10000);page.on('pageerror',e=>{errors.push({name:e.name,message:e.message,stack:e.stack});fs.writeFileSync(out+'/'+name+'-'+width+'-errors.json',JSON.stringify(errors,null,2));});
    page.on('request',r=>{if(['script','stylesheet','font'].includes(r.resourceType()) && /^https?:/.test(r.url()))remoteUI.push(r.url());});
    await page.route('https://**/*',r=>r.abort());
    await page.goto(base,{waitUntil:'load'});await page.waitForFunction(()=>window.MobileShell && window.DesktopLayout && window.LibraryHub && window.NativeShell);
    await page.waitForTimeout(200);
    if(process.env.LX_TEST_FONT_CSS){await page.addStyleTag({content:fs.readFileSync(process.env.LX_TEST_FONT_CSS,'utf8')});await page.evaluate(()=>document.fonts.ready);}
    await page.evaluate(()=>{
     const colours=[['#e98375','#8e3b54'],['#5e9db0','#254e75'],['#a191bf','#5a446d'],['#d1b57a','#81613b'],['#759688','#355449'],['#808aaf','#373c60']];
     const titles=['黄昏的慢镜头','周末去看海','夜色里的独白','那些年的旋律','晴天散步计划','专注这一刻'];
     const art=i=>'data:image/svg+xml;base64,'+btoa(`<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="${colours[i][0]}"/><stop offset="1" stop-color="${colours[i][1]}"/></linearGradient></defs><path fill="url(#g)" d="M0 0h500v500H0z"/><circle cx="340" cy="150" r="110" fill="#fff" opacity=".12"/><path d="M0 420Q120 180 270 350T550 270V500H0" fill="#fff" opacity=".12"/><text x="42" y="75" fill="#fff" opacity=".8" font-size="20" font-family="Arial" letter-spacing="5">LX COLLECTION</text><text x="42" y="415" fill="#fff" font-size="54" font-family="Arial">0${i+1}</text></svg>`);
     window.__uiSongs=titles.map((name,i)=>({id:'ui-'+i,name,singer:'LX Music',source:'wy',img:art(i),pic:art(i)}));
     currentListData={defaultList:[window.__uiSongs[0]],loveList:[],userList:titles.map((name,i)=>({id:'collection-'+i,name,list:window.__uiSongs.slice(0,i+1),cover:art(i)}))};
    });
    assert.deepEqual(await page.locator('#mobile-bottom-nav button').allTextContents(),['首页','歌单','一起听','我的']);
    assert.ok(await page.locator('#view-native-home').isVisible());
    assert.equal(await page.locator('header.h-16').isVisible(),false,'Top capsule header removed');
    await page.waitForFunction(()=>document.querySelectorAll('#native-home-posters button').length===4);
    assert.equal(await page.locator('#native-home-hot button').count(),0,'A pending hot-search request must not block playlist cards');
    await page.evaluate(()=>window.__releaseHot());await page.waitForFunction(()=>document.querySelectorAll('#native-home-hot button').length===4);
    if(width===375){
     await page.evaluate(()=>{window.__catalogFail=true;window.NativeShell.state.feed.lists=[];window.NativeShell.state.listsAt=0;window.NativeShell.go('home');});
     await page.waitForFunction(()=>window.NativeShell.state.feed.listOrder==='hot'&&document.querySelectorAll('#native-home-posters button').length===4);
     assert.ok(await page.getByText('推荐歌单',{exact:true}).isVisible());
     assert.ok(await page.evaluate(()=>window.__nativeCommands.some(c=>c.op==='musicApi'&&c.path.includes('sortId=hot'))),'A failed list request must retry despite a successful cached hot-search result');
    }
    await page.screenshot({path:out+'/'+name+'-'+width+'-home.png'});
    await page.locator('[data-native-page=mine]').click();
    for(const text of ['我的收藏','我的歌单','本地 / 网盘','设置','已下载'])assert.ok(await page.locator('#native-mine-grid').getByText(text,{exact:true}).isVisible());
    await page.screenshot({path:out+'/'+name+'-'+width+'-mine.png'});
    await page.evaluate(()=>window.NativeShell.go('downloads'));
    assert.ok(await page.getByText('离线音乐',{exact:true}).isVisible());
    await page.locator('.native-download-more').click();await page.getByText('分享歌曲、封面与歌词',{exact:true}).click();
    assert.ok(await page.evaluate(()=>window.__nativeCommands.some(c=>c.op==='shareDownload')));
    await page.locator('.native-sheet-close').click();
    await page.locator('.native-download-play').click();
    await page.waitForFunction(()=>typeof currentRawLrc==='string'&&currentRawLrc.includes('离线歌词测试'));
    assert.ok(await page.evaluate(()=>window.__nativeCommands.some(c=>c.op==='select'&&c.queue[0].offlineId===window.__offlineSong.offlineId)));
    await page.evaluate(()=>{if(!document.getElementById('view-player-detail').classList.contains('hidden'))window.toggleLyrics();});
    await page.locator('[data-native-page=room]').click();
    assert.equal(await page.locator('#native-room-create-form').isVisible(),false);assert.equal(await page.locator('#native-room-join-form').isVisible(),false);
    await page.locator('[data-fold=join]').click();assert.ok(await page.locator('#native-room-join-form').isVisible());
    await page.evaluate(()=>{window.__mockAccount=true;window.NativeShell.state.info={server:location.origin,hasAccount:true,username:'alice'};localStorage.setItem('lx_sync_user','alice');localStorage.setItem('lx_user_token','fixture');});
    await page.locator('#native-room-join-form [name=roomId]').fill('123456');await page.locator('#native-room-join-form button').click();
    await page.waitForFunction(()=>window.RoomSocial.state.open);
    await page.evaluate(()=>window.LXBridge.chat('room:chat-history',{revision:1,messages:window.__chatMessages}));
    await page.waitForFunction(()=>document.querySelector('[data-message-id=m1]'));
    assert.equal(await page.locator('#native-room-member-strip .native-member').count(),2);
    await page.evaluate(()=>{window.__firstChatNode=document.querySelector('[data-message-id=m1]');window.__chatMessages.push({id:'m2',kind:'text',text:'好呀 🎶',time:Date.now(),author:{name:'alice',nickname:'我'}});window.LXBridge.chat('room:chat-history',{revision:2,messages:window.__chatMessages});});
    assert.ok(await page.evaluate(()=>window.__firstChatNode===document.querySelector('[data-message-id=m1]')),'Unchanged chat rows must be reused');
    await page.locator('#room-chat-emoji').click();assert.ok(await page.locator('#room-emoji-grid button').count()>20);await page.locator('#room-chat-emoji').click();
    await page.locator('#room-chat-input').fill('输入文字不跳页');
    if(phone){
     await page.setViewportSize({width,height:330});await page.waitForTimeout(120);
     const keyboard=await page.evaluate(()=>{const r=document.getElementById('room-chat-input').getBoundingClientRect();return {top:r.top,bottom:r.bottom,height:innerHeight,scroll:scrollY,keyboard:document.body.classList.contains('native-chat-keyboard')};});
     assert.ok(keyboard.keyboard&&keyboard.top>=0&&keyboard.bottom<=keyboard.height,JSON.stringify(keyboard));assert.equal(keyboard.scroll,0);
     await page.screenshot({path:out+'/'+name+'-'+width+'-keyboard.png'});await page.setViewportSize({width,height:width===375?667:932});await page.locator('#room-chat-input').blur();
    }
    await page.screenshot({path:out+'/'+name+'-'+width+'-room.png'});
    await page.locator('#room-chat-more').click();assert.ok(await page.locator('#native-room-leave').isVisible());await page.locator('#native-room-leave').click();
    await page.waitForFunction(()=>!window.RoomSocial.state.open);
    for(const theme of ['apple','kugou','lx','apple']){
     await page.evaluate(theme=>{window.DesktopLayout.select(theme);window.LibraryHub.show();},theme);
     await page.waitForTimeout(120);
     const layout=await page.evaluate(()=>({width:innerWidth,scroll:document.documentElement.scrollWidth,theme:document.documentElement.dataset.appTheme,players:document.querySelectorAll('#audio-player').length,footers:document.querySelectorAll('#player-footer').length,install:getComputedStyle(document.querySelector('#pwa-install-btn')).display}));
     assert.ok(layout.scroll<=layout.width,JSON.stringify(layout));assert.equal(layout.players,1);assert.equal(layout.footers,1);assert.equal(layout.install,'none');assert.equal(layout.theme,theme);
     await page.screenshot({path:out+'/'+name+'-'+width+'-'+theme+'.png'});
     reports.push({browser:name,width,theme,layout});
    }
    await page.evaluate(()=>window.switchTab('settings'));await page.waitForTimeout(100);
    assert.ok(await page.locator('#desktop-layout-settings').isVisible());assert.ok(await page.getByText('更换音乐服务器',{exact:true}).isVisible());
    await page.screenshot({path:out+'/'+name+'-'+width+'-settings.png'});
    if(phone){
     await page.evaluate(()=>{window.__LX_PLAYER_GETTERS__.setRoomPlaylist(window.__uiSongs,0);window.playSong(window.__uiSongs[0],0);});
     await page.waitForFunction(()=>!document.getElementById('view-player-detail').classList.contains('hidden'));
     await page.waitForTimeout(300);
     await page.screenshot({path:out+'/'+name+'-'+width+'-player.png'});
     const player=await page.evaluate(()=>{
      const cover=document.getElementById('mobile-player-cover-container'),chain=[];
      for(let node=cover;node && chain.length<5;node=node.parentElement){const style=getComputedStyle(node),rect=node.getBoundingClientRect();chain.push({id:node.id,className:node.className,inline:node.getAttribute('style'),display:style.display,visibility:style.visibility,width:rect.width,height:rect.height,top:rect.top,left:rect.left});}
      return {width:innerWidth,height:innerHeight,visualHeight:visualViewport?.height,active:document.activeElement?.id,phone:matchMedia('(max-width:767px), (max-width:1024px) and (pointer:coarse)').matches,short:matchMedia('(max-height:540px)').matches,body:document.body.className,chain};
     });
     fs.writeFileSync(out+'/'+name+'-'+width+'-player.json',JSON.stringify(player,null,2));
     assert.ok(await page.locator('#mobile-player-cover-container').isVisible(),JSON.stringify(player));
     assert.equal(await page.evaluate(()=>document.querySelector('#audio-player').getAttribute('src')),null);
     if(width===375){
      const lyric=await page.evaluate(async()=>{
       initLyricPlayer();
       lyricPlayer.setLyric('[00:12.00]<0,5000,0>连续流动的歌词\n[00:18.00]下一行保持稳定\n[00:24.00]慢慢唱完这一首');
       // Exercise real rendering with deterministic media time. Slow CI frames must
       // not turn this check into a missing-snapshot test (covered by bridge tests).
       const originalNow=Object.getOwnPropertyDescriptor(performance,'now');let now=performance.now();
       Object.defineProperty(performance,'now',{configurable:true,value:()=>now});
       window.LXBridge.state({position:12,paused:false,playing:true,seeking:false,timelineRevision:2});
       const line=document.querySelector('.lyric-line'),next=line.nextElementSibling;
       const metric=()=>({height:line.offsetHeight,next:next.offsetTop,font:getComputedStyle(line).fontSize});
       const before=metric(),frames=[];
       for(let i=0;i<24;i++){
        now+=16;
        await new Promise(requestAnimationFrame);
        frames.push({time:audio.currentTime,progress:parseFloat(line.querySelector('.word-item').style.getPropertyValue('--word-progress'))||0});
       }
       const active=metric();
       window.LXBridge.state({paused:true,playing:false,position:audio.currentTime});
       const paused=audio.currentTime;await new Promise(r=>setTimeout(r,80));
       const afterPause=audio.currentTime;
       line.classList.remove('active');await new Promise(r=>setTimeout(r,450));
       const inactive=metric();
       if(originalNow)Object.defineProperty(performance,'now',originalNow);else delete performance.now;
       return {before,active,inactive,frames,paused,afterPause};
      });
      assert.deepEqual(lyric.before,lyric.active,'Highlight must not change line metrics');
      assert.deepEqual(lyric.active,lyric.inactive,'Removing highlight must not shift following lines');
      assert.ok(new Set(lyric.frames.map(f=>f.progress.toFixed(2))).size>=12,'Karaoke must advance between native snapshots: '+JSON.stringify(lyric));
      assert.equal(lyric.paused,lyric.afterPause,'Paused lyric time must stay fixed');
      fs.writeFileSync(out+'/'+name+'-lyrics.json',JSON.stringify(lyric,null,2));
      await page.screenshot({path:out+'/'+name+'-lyrics.png'});
     }
    }
    assert.deepEqual(errors,[],'Page JS errors');assert.deepEqual(remoteUI,[],'Packaged UI must not fetch scripts, styles or fonts');
    await context.close();
   }
  }finally{await browser.close();}
 }
 fs.writeFileSync(out+'/report.json',JSON.stringify(reports,null,2));console.log('PASS: '+reports.length+' layout checks, '+engines.length+' browser engine(s), native playback selection, no remote UI dependencies.');
})().catch(e=>{console.error(e);process.exitCode=1}).finally(()=>server.close());
