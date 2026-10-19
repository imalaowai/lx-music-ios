'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../generated/WebUI.html'),'utf8');
const source=/<script data-source="[^"]*lyric-parser\.js[^\"]*">([\s\S]*?)<\/script>/.exec(html)?.[1];
assert.ok(source,'Test the actual packaged lyric parser');
function parser(){let nativeTime=0,wall=0;const tasks=[],calls=[];class Timers{start(fn,delay){tasks.push({fn,delay});}clear(){tasks.length=0;}}
 const window={LyricUtils:{getNow:()=>wall,TimeoutTools:Timers},LXNative:{lyricTime:()=>nativeTime}};
 vm.runInNewContext(source,{window,console});const player=new window.LinePlayer({onPlay:(index,text,time)=>calls.push({index,text,time})});
 return {player,calls,tasks,time:(media,other=media)=>{nativeTime=media/1000;wall=other;}};
}
test('LRC fractional seconds, whole seconds and hour timestamps retain their exact precision',()=>{
 const f=parser();f.player.setLyric('[00:12.5]half\n[00:13.50]centiseconds\n[00:14.05]leading zero\n[00:15.005]milliseconds\n[00:16]whole second\n[1:02:03.45]hours',[]);
 assert.deepEqual(Array.from(f.player.lines,x=>x.time),[12500,13500,14050,15005,16000,3723450]);
});
test('Equivalent timestamp precision attaches translations to the same lyric line',()=>{
 const f=parser();f.player.setLyric('[00:12.50]original',['[00:12.500]translation']);assert.equal(f.player.lines.length,1);assert.equal(f.player.lines[0].extendedLyrics[0],'translation');
});
test('Native line changes and word timing share media time including LRC offset and playback rate',()=>{
 const f=parser();f.player.setLyric('[offset:200]\n[00:01.50]<0,100,0>one\n[00:02.50]<0,100,0>two\n[00:03.50]three',[]);
 f.time(1300,90000);f.player.play(1300);assert.equal(f.calls.at(-1).index,0);assert.equal(f.player._currentTime(),1500);
 f.time(2300,999999);f.tasks.shift().fn();assert.equal(f.calls.at(-1).index,1);assert.equal(f.player._currentTime(),2500);
 f.player.setPlaybackRate(2);assert.equal(f.player._currentTime(),2500,'Rate and offsets must not be applied twice');
 f.player.pause();f.time(2300,9999999);assert.equal(f.player._currentTime(),2500,'Unrelated wall clock cannot advance paused media');
});
