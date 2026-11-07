'use strict';

// This IPA retains the iOS RNTrackPlayer/SwiftAudioEx binary, whose getPosition
// and getDuration return seconds. The pinned JS fork divides both by 1000.
// Read these two methods from the real bridge; keep every other SDK operation
// (including seekTo, already in seconds) on its existing supported path.
module.exports=function nativeClockPlayer(player,native){
  const seconds=async method=>{
    if(typeof native?.[method]!=='function')throw Error('iOS native playback clock is unavailable');
    return native[method]();
  };
  return {...player,getPosition:()=>seconds('getPosition'),getDuration:()=>seconds('getDuration')};
};
