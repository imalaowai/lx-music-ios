#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>

// A native guard for the existing decoders, not another audio engine. Swift
// controls the hold; decoder pause does not wait for a suspended RN JS queue.
typedef void (^LXAudioResolve)(id);
typedef void (^LXAudioReject)(NSString *, NSString *, NSError *);
static atomic_bool LXOutputHeld = false;
static __weak id LXTrackInstance, LXFlacInstance;
static IMP LXTrackPlay, LXTrackPause, LXFlacResume, LXFlacPause, LXMetadataPlay;
static IMP LXTrackEmit;
extern void LXOwnDeliverRemoteCommand(NSString *command,NSNumber *position,NSTimeInterval eventAt);
static void LXTrackEmitted(id self,SEL selector,NSString *name,id body) {
    if([name hasPrefix:@"remote-"]) {
        NSMutableDictionary *event=[body isKindOfClass:NSDictionary.class]?[body mutableCopy]:[NSMutableDictionary dictionary];
        // Stamp at the native event source. Stamping after JS wakes would turn
        // a pre-disconnect queued remote command into a seemingly new action.
        event[@"nativeEventAt"]=@(NSProcessInfo.processInfo.systemUptime);body=event;
        // Next/previous are handled by LXNowPlayingCoordinator's direct native targets.
        // TrackPlayer has only one decoder item, so forwarding its skip events too would
        // create a second, competing route into Swift's authoritative song queue.
        NSDictionary *commands=@{@"remote-play":@"play",@"remote-pause":@"pause",@"remote-stop":@"pause",@"remote-seek":@"seek"};
        NSString *command=commands[name];
        if(command)LXOwnDeliverRemoteCommand(command,event[@"position"],[event[@"nativeEventAt"] doubleValue]);
    }
    ((void (*)(id,SEL,id,id))LXTrackEmit)(self,selector,name,body);
}
static void LXPauseDecoder(id target, IMP method, SEL selector) {
    if (!target || !method) return;
    @try { ((void (*)(id, SEL, id, id))method)(target, selector, ^(id value){}, ^(NSString *code, NSString *message, NSError *error){}); }
    @catch (NSException *exception) { NSLog(@"[Qiye] Native output-loss pause failed: %@", exception.name); }
}
static void LXTrackPaused(id self, SEL selector, LXAudioResolve resolve, LXAudioReject reject) {
    LXTrackInstance=self;
    ((void (*)(id,SEL,id,id))LXTrackPause)(self,selector,resolve,reject);
}
static void LXFlacPaused(id self, SEL selector, LXAudioResolve resolve, LXAudioReject reject) {
    LXFlacInstance=self;
    ((void (*)(id,SEL,id,id))LXFlacPause)(self,selector,resolve,reject);
}
static void LXTrackPlayed(id self, SEL selector, LXAudioResolve resolve, LXAudioReject reject) {
    LXTrackInstance=self;
    if (atomic_load(&LXOutputHeld)) { LXPauseDecoder(self,LXTrackPause,NSSelectorFromString(@"pause:rejecter:")); if(resolve)resolve(nil); return; }
    ((void (*)(id,SEL,id,id))LXTrackPlay)(self,selector,resolve,reject);
}
static void LXFlacResumed(id self, SEL selector, LXAudioResolve resolve, LXAudioReject reject) {
    LXFlacInstance=self;
    if (atomic_load(&LXOutputHeld)) { LXPauseDecoder(self,LXFlacPause,NSSelectorFromString(@"pauseStreamWithResolver:rejecter:")); if(resolve)resolve(nil); return; }
    ((void (*)(id,SEL,id,id))LXFlacResume)(self,selector,resolve,reject);
}
static void LXMetadataPlayed(id self, SEL selector, NSDictionary *options, LXAudioResolve resolve, LXAudioReject reject) {
    if (atomic_load(&LXOutputHeld)) {
        NSMutableDictionary *paused=[options mutableCopy] ?: [NSMutableDictionary dictionary];paused[@"playbackRate"]=@0;
        SEL pause=NSSelectorFromString(@"pauseNowPlaying:resolver:rejecter:");
        IMP method=[self respondsToSelector:pause]?[self methodForSelector:pause]:NULL;
        if(method){((void (*)(id,SEL,id,id,id))method)(self,pause,paused,resolve,reject);return;}
        if(resolve)resolve(nil);return;
    }
    ((void (*)(id,SEL,id,id,id))LXMetadataPlay)(self,selector,options,resolve,reject);
}
static IMP LXAudioHook(NSString *className, NSString *name, IMP replacement) {
    Class cls=NSClassFromString(className);SEL selector=NSSelectorFromString(name);Method method=class_getInstanceMethod(cls,selector);
    if(!cls || !method)return NULL;
    IMP original=method_getImplementation(method);class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));return original;
}
#ifndef LX_CARPLAY_TESTING
__attribute__((constructor))
#endif
static void LXOwnInstallAudioSafety(void) {
    static BOOL installed=NO;if(installed)return;installed=YES;
    LXTrackPause=LXAudioHook(@"RNTrackPlayer",@"pause:rejecter:",(IMP)LXTrackPaused);
    if(LXTrackPause)LXTrackPlay=LXAudioHook(@"RNTrackPlayer",@"play:rejecter:",(IMP)LXTrackPlayed);
    LXFlacPause=LXAudioHook(@"StreamingFlacPlayerModule",@"pauseStreamWithResolver:rejecter:",(IMP)LXFlacPaused);
    if(LXFlacPause)LXFlacResume=LXAudioHook(@"StreamingFlacPlayerModule",@"resumeStreamWithResolver:rejecter:",(IMP)LXFlacResumed);
    LXMetadataPlay=LXAudioHook(@"NowPlayingModule",@"playNowPlaying:resolver:rejecter:",(IMP)LXMetadataPlayed);
    LXTrackEmit=LXAudioHook(@"RNTrackPlayer",@"sendEventWithName:body:",(IMP)LXTrackEmitted);
    [NSNotificationCenter.defaultCenter addObserverForName:@"LXOwnAudioRouteHold" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
        BOOL held=[note.userInfo[@"held"] boolValue];BOOL previous=atomic_exchange(&LXOutputHeld,held);
        if(!held || previous)return;
        LXPauseDecoder(LXTrackInstance,LXTrackPause,NSSelectorFromString(@"pause:rejecter:"));
        LXPauseDecoder(LXFlacInstance,LXFlacPause,NSSelectorFromString(@"pauseStreamWithResolver:rejecter:"));
        NSMutableDictionary *info=[MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo mutableCopy];
        if(info){info[MPNowPlayingInfoPropertyPlaybackRate]=@0;MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=info;}
        MPNowPlayingInfoCenter.defaultCenter.playbackState=MPNowPlayingPlaybackStatePaused;
    }];
}
