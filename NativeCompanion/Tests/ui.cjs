// Integration review of the actual packaged page, including both browser engines.
const fs=require('node:fs'),path=require('node:path'),http=require('node:http'),assert=require('node:assert/strict');
const {chromium,webkit,devices}=require(process.env.LX_PLAYWRIGHT || 'playwright');
const root=path.resolve(__dirname,'..'),out=path.join(root,'build/ui-review');fs.mkdirSync(out,{recursive:true});
const html=fs.readFileSync(root+'/generated/WebUI.html'),bridge=fs.readFileSync(root+'/Resources/Bridge.js','utf8');
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
   for(const width of [1440,430,375]){
    const phone=width<700,context=await browser.newContext({...phone?devices['iPhone 13 Pro Max']:{},viewport:{width,height:phone?(width===375?667:932):950},serviceWorkers:'block'});
    await context.addInitScript(()=>{
     localStorage.setItem('lx_desktop_layout','apple');localStorage.setItem('lx_sync_mode','local');
     localStorage.setItem('lx_theme_profiles',JSON.stringify({apple:{colour:'rose'},kugou:{colour:'blue'}}));
     localStorage.setItem('lx_settings',JSON.stringify({autoResume:false,keepScreenAwake:false}));
     window.__nativeCommands=[];
     window.webkit={messageHandlers:{lxNative:{postMessage(message){
      window.__nativeCommands.push(message);
      queueMicrotask(()=>{
       window.LXBridge.reply(message.id,message.op==='appInfo'?{version:'1.1.1',server:location.origin,bundledUI:true}:true,null);
       if(message.op==='select')window.LXBridge.state({queueRevision:10,queue:message.queue,index:message.index,song:message.queue[message.index],paused:false,playing:true,position:12,duration:180,mode:'list'});
      });
     }}}};
    });
    await context.addInitScript({content:bridge});
    const page=await context.newPage(),errors=[],remoteUI=[];page.on('pageerror',e=>errors.push(e.stack));
    page.on('request',r=>{if(['script','stylesheet','font'].includes(r.resourceType()) && /^https?:/.test(r.url()))remoteUI.push(r.url());});
    await page.route('https://**/*',r=>r.abort());
    await page.goto(base,{waitUntil:'load'});await page.waitForFunction(()=>window.MobileShell && window.DesktopLayout && window.LibraryHub);
    await page.waitForTimeout(200);
    if(process.env.LX_TEST_FONT_CSS){await page.addStyleTag({content:fs.readFileSync(process.env.LX_TEST_FONT_CSS,'utf8')});await page.evaluate(()=>document.fonts.ready);}
    await page.evaluate(()=>{
     const colours=[['#e98375','#8e3b54'],['#5e9db0','#254e75'],['#a191bf','#5a446d'],['#d1b57a','#81613b'],['#759688','#355449'],['#808aaf','#373c60']];
     const titles=['黄昏的慢镜头','周末去看海','夜色里的独白','那些年的旋律','晴天散步计划','专注这一刻'];
     const art=i=>'data:image/svg+xml;base64,'+btoa(`<svg xmlns="http://www.w3.org/2000/svg" width="500" height="500"><defs><linearGradient id="g" x2="1" y2="1"><stop stop-color="${colours[i][0]}"/><stop offset="1" stop-color="${colours[i][1]}"/></linearGradient></defs><path fill="url(#g)" d="M0 0h500v500H0z"/><circle cx="340" cy="150" r="110" fill="#fff" opacity=".12"/><path d="M0 420Q120 180 270 350T550 270V500H0" fill="#fff" opacity=".12"/><text x="42" y="75" fill="#fff" opacity=".8" font-size="20" font-family="Arial" letter-spacing="5">LX COLLECTION</text><text x="42" y="415" fill="#fff" font-size="54" font-family="Arial">0${i+1}</text></svg>`);
     window.__uiSongs=titles.map((name,i)=>({id:'ui-'+i,name,singer:'LX Music',source:'wy',img:art(i),pic:art(i)}));
     currentListData={defaultList:[window.__uiSongs[0]],loveList:[],userList:titles.map((name,i)=>({id:'collection-'+i,name,list:window.__uiSongs.slice(0,i+1),cover:art(i)}))};
    });
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
