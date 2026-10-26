'use strict';

// The phone UI and room client own the queue. The reference's TrackPlayer and
// native FLAC decoder are the only audio outputs. No HTML/second AVPlayer runs.
module.exports = function createDriver({player, stream, State, Capability, RepeatMode, report, ready}) {
  let setup, chain = Promise.resolve(), latest = 0, active = null, switching = false, probing = false;
  let latestWanted = false;
  const num = value => Number.isFinite(Number(value)) ? Number(value) : 0;
  const current = item => active === item && item.generation === latest;
  function failOnce(item,error) {
    if (!current(item) || item.failed) return;
    // Swift pauses after a failure. Pausing used to sample again and report the
    // same failed query forever, flooding both the RN and main queues.
    item.failed=true;
    report({generation:item.generation,error:error?.message||String(error)});
  }
  async function initialize() {
    if (!setup) setup = (async () => {
      await player.setupPlayer({autoUpdateMetadata:false, waitForBuffer:true, maxCacheSize:65536, iosCategory:'playback', iosCategoryMode:'default'});
      await player.updateOptions({capabilities:[Capability.Play,Capability.Pause,Capability.Stop,Capability.SeekTo,Capability.SkipToNext,Capability.SkipToPrevious], stopWithApp:false});
      await player.setRepeatMode(RepeatMode.Off);
      ready?.();
    })().catch(error => {setup = null; throw error;});
    return setup;
  }
  async function sample(ended = false) {
    const item = active;
    if (!item || item.failed || switching || probing || !current(item)) return;
    probing = true;
    try {
      const flac = item.engine === 'flac';
      const [position,duration,state,rate] = flac
        ? await Promise.all([stream.getPosition(),stream.getDuration(),stream.getState(),Promise.resolve(1)])
        : await Promise.all([player.getPosition(),player.getDuration(),player.getState(),player.getRate()]);
      if (!current(item) || switching) return;
      const playing = flac ? state === 'playing' : state === State.Playing;
      const buffering = flac ? ['loading','buffering'].includes(state) : [State.Buffering,State.Connecting].includes(state);
      // Old queued EOF events cannot finish a newly loaded track at position 0.
      const atEnd = num(duration) > 0 && num(position) >= num(duration) - 0.8;
      const finished = ended && atEnd && !item.ended;
      if (finished) item.ended = true;
      report({generation:item.generation,position:num(position),duration:num(duration),playing:playing&&!item.ended,loading:buffering,rate:playing?num(rate)||1:0,ended:finished,engine:item.engine,sampledAt:Date.now()});
    } catch (error) {
      failOnce(item,error);
    } finally {probing = false;}
  }
  async function execute(request) {
    const {operation,generation} = request, args = request.args || {};
    if (generation !== latest) return {superseded:true};
    // Browsing/restoring preferences must not construct the audio SDK and its
    // MediaRemote services. Volume is applied with the first actual load.
    if(!setup && operation!=='load')return {};
    await initialize();
    if (generation !== latest) return {superseded:true};
    if (operation === 'transition') {
      const item=active;active=null;
      if(item?.engine==='flac') await stream.pause();
      else if(item) await player.pause();
      return {};
    }
    if (operation === 'clear' || operation === 'load') {
      switching = true; active = null;
      try {
        // Keep the same session through a handoff. reset() unregisters remote
        // controls; stop()/an empty queue can also retire the Now Playing app.
        if(operation==='clear') await player.reset();
        else await player.pause();
        if (stream?.reset) await stream.reset();
        if (generation !== latest) return {superseded:true};
        if (operation === 'clear') return {};
        const flac = /^https?:/i.test(args.url) && /^(flac|flac24bit)$/i.test(args.quality) && typeof stream?.openStream === 'function';
        const item = {generation,engine:flac?'flac':'track-player',ended:false}; active = item;
        const volume = Math.max(0,Math.min(1,num(args.volume ?? 1)));
        if (flac) {
          await stream.openStream(args.url,{'User-Agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 Mobile'},volume,1,false);
          if (!current(item)) {await stream.reset();return {superseded:true};}
          if (num(args.position)>0) await stream.seekTo(num(args.position));
          if (!args.paused && latestWanted && current(item)) await stream.resume();
          if (!latestWanted && current(item)) await stream.pause();
        } else {
          const id='own-ui-'+generation;
          await player.add({id,url:args.url,title:args.title||'未知歌曲',artist:args.artist||'',album:args.album||'',artwork:args.artwork||undefined});
          if (!current(item)) return {superseded:true};
          const queue=await player.getQueue(),index=queue.findIndex(track=>track.id===id);
          if(!current(item))return {superseded:true};
          if(index<0)throw new Error('新歌曲没有加入原生播放队列');
          await player.skip(index);
          if(!current(item))return {superseded:true};
          // Remove old entries only after the new item is selected. Descending
          // indices match the preserved SDK's sequential remove implementation.
          const remove=queue.map((_,i)=>i).filter(i=>i!==index).reverse();
          if(remove.length)await player.remove(remove);
          if(!current(item))return {superseded:true};
          await player.setVolume(volume);
          if (num(args.position)>0) await player.seekTo(num(args.position));
          if (!args.paused && latestWanted && current(item)) await player.play();
          if (!latestWanted && current(item)) await player.pause();
        }
        return {engine:item.engine};
      } finally {switching = false; void sample();}
    }
    const item = active;
    if (!item || !current(item)) return {};
    const target = item.engine === 'flac' ? stream : player;
    if (operation === 'play' && latestWanted) {item.ended=false;await (item.engine==='flac'?target.resume():target.play());if(!latestWanted)await target.pause();}
    else if (operation === 'play') return {superseded:true};
    else if (operation === 'pause') await target.pause();
    else if (operation === 'seek') {item.ended=false;await target.seekTo(Math.max(0,num(args.position)));}
    else if (operation === 'volume') await target.setVolume(Math.max(0,Math.min(1,num(args.volume))));
    else throw new Error('未知原生播放操作：'+operation);
    void sample();return {};
  }
  function run(request) {
    if (request.operation === 'probe') return sample().then(()=>({}));
    if (['load','clear','transition'].includes(request.operation)) latest=Math.max(latest,num(request.generation));
    // Record intent at receipt, before an asynchronous load/seek can block the
    // serialized decoder queue. An older captured load must not autoplay later.
    if (request.generation===latest) {
      if (request.operation==='load') latestWanted=!request.args?.paused;
      else if (request.operation==='play') latestWanted=true;
      else if (['pause','clear','transition'].includes(request.operation)) latestWanted=false;
    }
    if (request.operation==='pause' && request.generation===latest && active && current(active)) {
      const target=active.engine==='flac'?stream:player;
      Promise.resolve().then(()=>target.pause()).catch(()=>{});
    }
    const task=chain.then(()=>execute(request));chain=task.catch(()=>{});return task;
  }
  function nativeEvent(engine,event={}) {
    if (!active || switching || active.engine!==engine || !current(active)) return;
    if (event.type==='error') failOnce(active,new Error(event.message||event.error||'原生音源播放失败'));
    else void sample(event.type==='ended');
  }
  return {run,sample,nativeEvent};
};
