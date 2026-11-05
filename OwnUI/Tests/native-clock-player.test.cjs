const {test}=require('node:test'),assert=require('node:assert/strict');
const clockPlayer=require('../native-clock-player.js'),createDriver=require('../audio-driver.js');

// iOS bridge contract verified against the retained IPA's RNTrackPlayer Swift
// implementations and SwiftAudioEx CMTimeGetSeconds getters. Deliberately keep
// the pinned JS fork's incorrect /1000 reads in this boundary fixture.
function fixture(){
 const state={position:12.25,duration:180.5,rate:1,state:'playing',queue:[]},calls=[],reports=[];
 const native={getPosition:async()=>state.position,getDuration:async()=>state.duration};
 const sdk={getPosition:async()=>(await native.getPosition())/1000,getDuration:async()=>(await native.getDuration())/1000,
  getState:async()=>state.state,getRate:async()=>state.rate,getQueue:async()=>state.queue,
  setupPlayer:async()=>{},updateOptions:async()=>{},setRepeatMode:async()=>{},setVolume:async()=>{},
  pause:async()=>{state.state='paused';},play:async()=>{state.state='playing';},
  add:async track=>{state.queue.push(track);},skip:async()=>{},remove:async()=>{},
  seekTo:async seconds=>{calls.push(seconds);state.position=seconds;},reset:async()=>{state.queue=[];}};
 const player=clockPlayer(sdk,native);
 const driver=createDriver({player,State:{Playing:'playing',Paused:'paused',Buffering:'buffering',Connecting:'loading'},RepeatMode:{Off:0},report:value=>reports.push(value)});
 return {state,sdk,player,driver,calls,reports};
}
const settle=()=>new Promise(resolve=>setImmediate(resolve));
test('iOS seconds bypass the pinned wrapper /1000 conversion without changing seek units',async()=>{
 const f=fixture();assert.equal(await f.sdk.getDuration(),.1805);
 assert.equal(await f.player.getDuration(),180.5);assert.equal(await f.player.getPosition(),12.25);
 await f.player.seekTo(45.75);assert.deepEqual(f.calls,[45.75]);assert.equal(await f.player.getPosition(),45.75);
});
test('the production driver publishes a seekable full song and continuous native seconds',async()=>{
 const f=fixture();await f.driver.run({operation:'load',generation:1,args:{url:'https://audio.invalid/song.mp3',quality:'320k'}});await settle();
 assert.equal(f.reports.at(-1).duration,180.5);assert.equal(f.reports.at(-1).position,12.25);
 assert.equal(f.reports.at(-1).rate,1);assert.equal(f.reports.at(-1).playing,true);
 f.state.position=16.25;await f.driver.sample();assert.equal(f.reports.at(-1).position,16.25);
 await f.driver.run({operation:'seek',generation:1,args:{position:45.75}});await settle();
 assert.equal(f.calls.at(-1),45.75);assert.equal(f.reports.at(-1).position,45.75);
});
test('EOF cannot finish an iOS song early and pause retains the exact clock',async()=>{
 const f=fixture();await f.driver.run({operation:'load',generation:1,args:{url:'https://audio.invalid/song.mp3'}});await settle();
 f.driver.nativeEvent('track-player',{type:'ended'});await settle();assert.equal(f.reports.filter(r=>r.ended).length,0);
 await f.driver.run({operation:'pause',generation:1});await settle();assert.equal(f.reports.at(-1).playing,false);assert.equal(f.reports.at(-1).position,12.25);
 f.state.position=180.5;f.driver.nativeEvent('track-player',{type:'ended'});await settle();assert.equal(f.reports.filter(r=>r.ended).length,1);
});
test('missing native clock fails during playback rather than breaking app initialization',async()=>{
 const player=clockPlayer({seekTo:async()=>{}},null);assert.equal(typeof player.seekTo,'function');
 await assert.rejects(player.getDuration(),/native playback clock/);
});
