const test=require('node:test'),assert=require('node:assert/strict');
const create=require('../audio-driver.js');
const State={Playing:3,Paused:2,Buffering:6,Connecting:8},Capability={Play:1,Pause:2,Stop:3,SeekTo:4,SkipToNext:5,SkipToPrevious:6};
function fixture(){
 const reports=[],calls=[],state={position:0,duration:180,state:State.Paused,rate:1,queue:[],current:0};
 const player={};for(const name of ['setupPlayer','updateOptions','setRepeatMode','reset','stop','add','setVolume','play','pause','seekTo'])player[name]=async value=>{calls.push([name,value]);if(['reset','stop'].includes(name)){state.position=0;state.state=State.Paused;}if(name==='play')state.state=State.Playing;if(name==='pause')state.state=State.Paused;if(name==='seekTo')state.position=value;};
 for(const [name,key]of [['getPosition','position'],['getDuration','duration'],['getState','state'],['getRate','rate']])player[name]=async()=>state[key];
 const add=player.add;player.add=async track=>{await add(track);state.queue.push(track);return state.queue.length-1;};
 const reset=player.reset;player.reset=async()=>{await reset();state.queue=[];state.current=0;};
 player.getQueue=async()=>state.queue.slice();
 player.skip=async index=>{calls.push(['skip',index]);state.current=index;state.position=0;};
 player.remove=async indexes=>{calls.push(['remove',indexes]);for(const i of indexes){if(i===state.current)continue;state.queue.splice(i,1);if(i<state.current)state.current--;}};
 const stream={};for(const name of ['reset','openStream','resume','pause','seekTo','setVolume'])stream[name]=async(...args)=>{calls.push(['flac.'+name,...args]);if(name==='resume')state.state='playing';if(name==='pause')state.state='paused';if(name==='seekTo')state.position=args[0];};
 stream.getPosition=async()=>state.position;stream.getDuration=async()=>state.duration;stream.getState=async()=>state.state;
 const driver=create({player,stream,State,Capability,RepeatMode:{Off:0},report:x=>reports.push(x)});
 const load=(generation,extra={})=>driver.run({operation:'load',generation,args:{url:'https://cdn.invalid/a.mp3',quality:'320k',title:'自己的歌曲',volume:1,...extra}});
 return {driver,load,player,stream,state,calls,reports};
}
const settle=()=>new Promise(r=>setImmediate(r));
test('idle preference restoration and clearing do not initialize media services',async()=>{
 const f=fixture();
 for(const operation of ['volume','pause','transition','clear'])await f.driver.run({operation,generation:1,args:{volume:.5}});
 assert.equal(f.calls.length,0);
 await f.load(2);assert.equal(f.calls.filter(x=>x[0]==='setupPlayer').length,1);
});
test('changing tracks does not reset the lock-screen session',async()=>{
 const f=fixture();await f.load(1);await f.load(2);
 assert.equal(f.calls.filter(x=>x[0]==='reset').length,0,'track replacement must not call the SDK reset that unregisters remote controls');
 assert.equal(f.calls.filter(x=>x[0]==='stop').length,0);
 assert.deepEqual(f.state.queue.map(x=>x.id),['own-ui-2'],'old tracks are removed after the handoff');
});
test('many track handoffs keep one current decoder entry and genuine clear still empties it',async()=>{
 const f=fixture();for(let i=1;i<=30;i++)await f.load(i);
 assert.deepEqual(f.state.queue.map(x=>x.id),['own-ui-30']);assert.equal(f.state.current,0);
 await f.driver.run({operation:'clear',generation:31});assert.equal(f.state.queue.length,0);assert.equal(f.calls.filter(x=>x[0]==='reset').length,1);
});
test('resolving a replacement track pauses old audio without resetting the session',async()=>{
 const f=fixture();await f.load(1);f.calls.length=0;
 await f.driver.run({operation:'transition',generation:2});
 assert.ok(f.calls.some(x=>x[0]==='pause'));
 assert.ok(!f.calls.some(x=>['reset','flac.reset'].includes(x[0])));
 await f.load(3);assert.equal(f.state.state,State.Playing);
});
test('owned selection uses native TrackPlayer and keeps metadata, seek and volume',async()=>{const f=fixture();await f.load(1,{position:12,volume:.4});await settle();assert.ok(f.calls.some(x=>x[0]==='add'&&x[1].title==='自己的歌曲'));assert.ok(f.calls.some(x=>x[0]==='seekTo'&&x[1]===12));assert.ok(f.calls.some(x=>x[0]==='setVolume'&&x[1]===.4));assert.equal(f.reports.at(-1).playing,true);});
test('rapid selection cancels stale loads before they open audio',async()=>{const f=fixture();await Promise.all([f.load(1),f.load(2),f.load(3)]);assert.equal(f.calls.filter(x=>x[0]==='add').length,1);assert.equal(f.calls.find(x=>x[0]==='add')[1].id,'own-ui-3');});
test('paused room restore never starts audio',async()=>{const f=fixture();await f.load(1,{paused:true,position:45});assert.equal(f.calls.filter(x=>x[0]==='play').length,0);assert.ok(f.calls.some(x=>x[0]==='seekTo'&&x[1]===45));});
test('streaming lossless uses the preserved reference FLAC decoder',async()=>{const f=fixture();await f.load(1,{url:'https://cdn.invalid/signed',quality:'flac'});assert.equal(f.calls.filter(x=>x[0]==='add').length,0);assert.equal(f.calls.filter(x=>x[0]==='flac.openStream').length,1);assert.ok(f.calls.some(x=>x[0]==='flac.resume'));});
test('EOF is deduplicated and an old end event cannot skip a fresh track',async()=>{const f=fixture();await f.load(1);await settle();f.state.position=180;f.driver.nativeEvent('track-player',{type:'ended'});await settle();f.driver.nativeEvent('track-player',{type:'ended'});await settle();assert.equal(f.reports.filter(x=>x.ended).length,1);await f.load(2);await settle();f.driver.nativeEvent('track-player',{type:'ended'});await settle();assert.equal(f.reports.filter(x=>x.ended).length,1);});
test('pause, seek and a stale command cannot affect a newer selection',async()=>{const f=fixture();await f.load(2);const pauses=f.calls.filter(x=>x[0]==='pause').length;await f.driver.run({operation:'pause',generation:1});assert.equal(f.calls.filter(x=>x[0]==='pause').length,pauses);await f.driver.run({operation:'seek',generation:2,args:{position:36}});await f.driver.run({operation:'pause',generation:2});assert.equal(f.state.position,36);assert.equal(f.state.state,State.Paused);});
test('failed load does not poison future playback',async()=>{const f=fixture();const add=f.player.add;f.player.add=async()=>{throw Error('decode failure');};await assert.rejects(f.load(1),/decode failure/);f.player.add=add;await f.load(2);assert.equal(f.state.state,State.Playing);});
test('in-flight progress from a previous track is discarded',async()=>{const f=fixture();await f.load(1);await settle();let release;f.player.getPosition=()=>new Promise(r=>{release=r;});const task=f.driver.sample();await f.load(2);release(179);await task;assert.ok(!f.reports.some(x=>x.generation===2&&x.position===179));});
test('a failed progress probe cannot feed a native pause/error loop',async()=>{
 const f=fixture();await f.load(1);await settle();let failures=0;const pending=[];
 f.player.getPosition=async()=>{throw Error('native probe failed');};
 const driver=create({player:f.player,stream:f.stream,State,Capability,RepeatMode:{Off:0},report:value=>{
  if(!value.error)return;failures++;
  // The production Swift Player.fail pauses the native core on an error.
  // Bound the old loop so this regression can fail without hanging the runner.
  if(failures<32)pending.push(driver.run({operation:'pause',generation:value.generation}));
 }});
 await driver.run({operation:'load',generation:1,args:{url:'https://cdn.invalid/a.mp3',quality:'320k'}});await settle();await Promise.all(pending);await settle();
 assert.equal(failures,1,'one decoder error must yield one terminal failure, never a pause/probe storm');
 const previous=failures;await driver.run({operation:'probe',generation:1});await settle();assert.equal(failures,previous);
});

test('repeated decoder errors stop at one report and a fresh track recovers',async()=>{
 const f=fixture();await f.load(1);await settle();
 for(let i=0;i<20;i++)f.driver.nativeEvent('track-player',{type:'error',message:'decode failed'});
 await f.driver.run({operation:'pause',generation:1});await settle();
 assert.equal(f.reports.filter(x=>x.error).length,1);
 await f.load(2);await settle();
 assert.equal(f.reports.at(-1).generation,2);assert.equal(f.reports.at(-1).playing,true);
});

test('a pause received while TrackPlayer.add is pending prevents late autoplay',async()=>{
 const f=fixture();let release;const add=f.player.add;f.player.add=async track=>{await add(track);await new Promise(r=>release=r);};
 const loading=f.load(1);await settle();assert.equal(typeof release,'function');
 const paused=f.driver.run({operation:'pause',generation:1});release();await Promise.all([loading,paused]);
 assert.equal(f.calls.filter(c=>c[0]==='play').length,0,'captured unpaused load must respect the newer pause');
});
test('a pause received while FLAC opens prevents a delayed resume',async()=>{
 const f=fixture();let release;const open=f.stream.openStream;f.stream.openStream=async(...args)=>{await open(...args);await new Promise(r=>release=r);};
 const loading=f.load(1,{quality:'flac'});await settle();const paused=f.driver.run({operation:'pause',generation:1});release();await Promise.all([loading,paused]);
 assert.equal(f.calls.filter(c=>c[0]==='flac.resume').length,0);
});
test('a queued play superseded by a newer pause cannot transiently restart sound',async()=>{
 const f=fixture();await f.load(1,{paused:true});let release;const seek=f.player.seekTo;f.player.seekTo=async p=>{await seek(p);await new Promise(r=>release=r);};
 const seeking=f.driver.run({operation:'seek',generation:1,args:{position:20}});await settle();
 const play=f.driver.run({operation:'play',generation:1}),pause=f.driver.run({operation:'pause',generation:1});release();await Promise.all([seeking,play,pause]);assert.equal(f.calls.filter(c=>c[0]==='play').length,0);
});
