import '../shim'
import React from 'react'
import { NativeEventEmitter, NativeModules, requireNativeComponent } from 'react-native'
import { Navigation } from 'react-native-navigation'
import TrackPlayer, { Event, State, Capability, RepeatMode } from 'react-native-track-player'
import createDriver from './audio-driver.js'

const bridge = NativeModules.LXOwnUIBridge
const emitter = new NativeEventEmitter(bridge)
const driver = createDriver({player:TrackPlayer, stream:NativeModules.StreamingFlacPlayerModule, State, Capability, RepeatMode, report:value=>bridge.reportState(value),ready:()=>bridge.audioReady()})
emitter.addListener('own-ui-audio-command', request => {
  driver.run(request).then(value=>bridge.complete(request.ticket,value||{},''), error=>bridge.complete(request.ticket,{},error.message||String(error)))
})
TrackPlayer.addEventListener(Event.PlaybackState, value=>driver.nativeEvent('track-player',value))
TrackPlayer.addEventListener(Event.PlaybackError, value=>driver.nativeEvent('track-player',{...value,type:'error'}))
TrackPlayer.addEventListener(Event.PlaybackQueueEnded, value=>driver.nativeEvent('track-player',{...value,type:'ended'}))
// Remote transport is delivered once at the native SDK emitter, before a
// backgrounded JS queue can delay/replay the same command.
if (NativeModules.StreamingFlacPlayerModule) new NativeEventEmitter(NativeModules.StreamingFlacPlayerModule).addListener('streaming-flac-event',event=>driver.nativeEvent('flac',event))

const OwnRoot = requireNativeComponent('LXOwnUIRoot')
const OwnScreen = () => React.createElement(OwnRoot,{style:{flex:1}})
Navigation.registerComponent('LXOwnUI.Screen',()=>OwnScreen)
Navigation.events().registerAppLaunchedListener(()=>{
  bridge.ready()
  Navigation.setRoot({root:{component:{name:'LXOwnUI.Screen',options:{topBar:{visible:false},statusBar:{drawBehind:false,visible:true,style:'dark'},layout:{componentBackgroundColor:'#ffffff'}}}}}).catch(error=>bridge.bootError(error.message||String(error)))
})
