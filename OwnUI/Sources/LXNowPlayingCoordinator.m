#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <math.h>

// The preserved SDKs decode audio. This coordinator alone publishes the owned
// player's lock-screen information. SDK reset/artwork callbacks must not revoke
// it while a track is selected (including pause, buffering and room changes).
static atomic_bool LXNPOwned=false;
static _Thread_local BOOL LXNPWriting=NO;
static IMP LXNPOriginalInfo, LXNPOriginalState, LXNPOriginalEnabled, LXNPOriginalEnd;
static NSSet<MPRemoteCommand *> *LXNPCommands;
static void LXNPLegacyInfo(id self,SEL selector,NSDictionary *info) {
    if(atomic_load(&LXNPOwned) && !LXNPWriting && self==MPNowPlayingInfoCenter.defaultCenter)return;
    ((void (*)(id,SEL,id))LXNPOriginalInfo)(self,selector,info);
}
static void LXNPLegacyState(id self,SEL selector,MPNowPlayingPlaybackState state) {
    if(atomic_load(&LXNPOwned) && !LXNPWriting && self==MPNowPlayingInfoCenter.defaultCenter)return;
    ((void (*)(id,SEL,MPNowPlayingPlaybackState))LXNPOriginalState)(self,selector,state);
}
static void LXNPLegacyEnabled(id self,SEL selector,BOOL enabled) {
    if(atomic_load(&LXNPOwned) && !LXNPWriting && [LXNPCommands containsObject:self])return;
    ((void (*)(id,SEL,BOOL))LXNPOriginalEnabled)(self,selector,enabled);
}
static void LXNPLegacyEnd(id self,SEL selector) {
    if(atomic_load(&LXNPOwned) && !LXNPWriting)return;
    ((void (*)(id,SEL))LXNPOriginalEnd)(self,selector);
}
static IMP LXNPHook(Class cls,SEL selector,IMP replacement) {
    Method method=class_getInstanceMethod(cls,selector);if(!method)return NULL;
    IMP previous=method_getImplementation(method);
    class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(method));return previous;
}
static void LXNPMain(void (^action)(void)) { if(NSThread.isMainThread)action();else dispatch_async(dispatch_get_main_queue(),action); }
static void LXNPSendRemote(NSString *command,NSNumber *position) {
    if(!atomic_load(&LXNPOwned))return;
    NSTimeInterval eventAt=NSProcessInfo.processInfo.systemUptime;
    LXNPMain(^{
        if(!atomic_load(&LXNPOwned))return;
        NSMutableDictionary *info=[@{@"command":command,@"eventAt":@(eventAt)} mutableCopy];
        if(position)info[@"position"]=position;
        [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnRemoteCommand" object:nil userInfo:info];
    });
}

@interface LXNowPlayingCoordinator:NSObject
@property(nonatomic,strong) NSDictionary *snapshot;
@property(nonatomic,strong) NSDictionary *publishedInfo;
@property(nonatomic,strong) NSCache<NSString *,MPMediaItemArtwork *> *covers;
@property(nonatomic,strong) NSURLSessionDataTask *coverTask;
@property(nonatomic,strong) MPMediaItemArtwork *artwork;
@property(nonatomic,strong) MPMediaItemArtwork *placeholder;
@property(nonatomic,copy) NSString *targetKey;
@property(nonatomic,copy) NSString *presentedKey;
@property(nonatomic,copy) NSString *coverPath;
@property(nonatomic) NSUInteger coverEpoch;
@property(nonatomic) NSInteger generation;
@property(nonatomic) NSInteger presentedGeneration;
@property(nonatomic) BOOL held;
@property(nonatomic) BOOL controlsInstalled;
@property(nonatomic) BOOL receivingRemote;
+ (instancetype)shared;
- (void)receive:(NSDictionary *)value;
- (void)clear;
- (void)installControls;
- (void)publish;
- (void)finishArtwork:(MPMediaItemArtwork *)artwork epoch:(NSUInteger)epoch;
@end
@implementation LXNowPlayingCoordinator
+ (instancetype)shared { static id owner;static dispatch_once_t once;dispatch_once(&once,^{owner=[self new];});return owner; }
- (instancetype)init {
    if((self=[super init])) {
        _covers=[NSCache new];_covers.totalCostLimit=8*1024*1024;_covers.countLimit=20;_generation=-1;
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256,256)];
        UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
            [[UIColor colorWithRed:0.12 green:0.25 blue:0.27 alpha:1] setFill];UIRectFill(CGRectMake(0,0,256,256));
            UIImage *note=[[UIImage systemImageNamed:@"music.note"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            [note drawInRect:CGRectMake(80,64,96,128)];
        }];
        _placeholder=[[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size){return image;}];
    }return self;
}
- (BOOL)wanted { return [self.snapshot[@"wanted"] boolValue] && ![self.snapshot[@"interrupted"] boolValue] && !self.held; }
- (void)installControls {
    MPRemoteCommandCenter *center=MPRemoteCommandCenter.sharedCommandCenter;
    if(!LXNPCommands)LXNPCommands=[NSSet setWithArray:@[center.playCommand,center.pauseCommand,center.stopCommand,center.togglePlayPauseCommand,center.nextTrackCommand,center.previousTrackCommand,center.changePlaybackPositionCommand,center.skipForwardCommand,center.skipBackwardCommand,center.seekForwardCommand,center.seekBackwardCommand]];
    // Called at first publication and once after SDK setup. The native handlers
    // replace the SDK/legacy duplicates, so each lock-screen tap is delivered
    // once and does not wait for JavaScript to wake in the background.
    for(MPRemoteCommand *command in LXNPCommands)[command removeTarget:nil];
    NSArray *pairs=@[@[center.playCommand,@"play"],@[center.pauseCommand,@"pause"],@[center.stopCommand,@"pause"],@[center.togglePlayPauseCommand,@"toggle"],@[center.nextTrackCommand,@"next"],@[center.previousTrackCommand,@"previous"]];
    for(NSArray *pair in pairs) {
        NSString *name=pair[1];
        [(MPRemoteCommand *)pair[0] addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event){LXNPSendRemote(name,nil);return MPRemoteCommandHandlerStatusSuccess;}];
    }
    [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event){
        if(![event isKindOfClass:MPChangePlaybackPositionCommandEvent.class])return MPRemoteCommandHandlerStatusCommandFailed;
        LXNPSendRemote(@"seek",@(((MPChangePlaybackPositionCommandEvent *)event).positionTime));return MPRemoteCommandHandlerStatusSuccess;
    }];
    self.controlsInstalled=YES;[self updateControls];
}
- (void)updateControls {
    BOOL before=LXNPWriting;LXNPWriting=YES;
    MPRemoteCommandCenter *center=MPRemoteCommandCenter.sharedCommandCenter;BOOL active=self.snapshot.count>0;
    center.playCommand.enabled=active && !self.wanted;center.pauseCommand.enabled=active && self.wanted;
    center.stopCommand.enabled=active;center.togglePlayPauseCommand.enabled=NO;
    center.nextTrackCommand.enabled=active;center.previousTrackCommand.enabled=active;center.changePlaybackPositionCommand.enabled=active;
    center.skipForwardCommand.enabled=NO;center.skipBackwardCommand.enabled=NO;center.seekForwardCommand.enabled=NO;center.seekBackwardCommand.enabled=NO;
    LXNPWriting=before;
}
- (void)receive:(NSDictionary *)value {
    NSString *key=[value[@"songId"] isKindOfClass:NSString.class]?value[@"songId"]:@"";if(!key.length)return;
    NSInteger generation=[value[@"generation"] integerValue];if(generation<self.generation)return;
    self.generation=generation;self.snapshot=[value copy];self.targetKey=key;
    atomic_store(&LXNPOwned,true);
    if(!self.controlsInstalled)[self installControls];
    NSString *path=[value[@"artwork"] isKindOfClass:NSString.class]?value[@"artwork"]:@"";
    if(![self.coverPath isEqualToString:path]) {
        [self.coverTask cancel];self.coverTask=nil;self.coverPath=path;NSUInteger epoch=++self.coverEpoch;
        MPMediaItemArtwork *cached=[self.covers objectForKey:path];
        if(cached)self.artwork=cached;
        else if(!path.length)self.artwork=self.placeholder;
        else [self fetchArtwork:path epoch:epoch];
    }
    [self publish];
}
- (void)publish {
    if(!self.snapshot.count)return;
    // A new stream may take time to resolve/open. Keep the last complete card
    // until the replacement is ready; actual pause/output loss always wins.
    if(self.wanted && [self.snapshot[@"loading"] boolValue] && self.publishedInfo.count && self.generation!=self.presentedGeneration) {
        [self updateControls];return;
    }
    NSDictionary *value=self.snapshot;NSMutableDictionary *info=[NSMutableDictionary dictionary];
    info[MPMediaItemPropertyTitle]=value[@"title"]?:@"";info[MPMediaItemPropertyArtist]=value[@"artist"]?:@"";info[MPMediaItemPropertyAlbumTitle]=value[@"album"]?:@"";
    info[MPNowPlayingInfoPropertyExternalContentIdentifier]=self.targetKey;
    info[MPMediaItemPropertyMediaType]=@(MPMediaTypeMusic);
    double duration=[value[@"duration"] doubleValue];if(isfinite(duration) && duration>0)info[MPMediaItemPropertyPlaybackDuration]=@(duration);
    double elapsed=[value[@"elapsedTime"] doubleValue];info[MPNowPlayingInfoPropertyElapsedPlaybackTime]=@(isfinite(elapsed)?MAX(0,elapsed):0);
    // Show the user's play/pause intent through buffering, without reporting
    // every transient decoder zero-rate as a pause and changing the controls.
    double rate=[value[@"playbackRate"] doubleValue];info[MPNowPlayingInfoPropertyPlaybackRate]=self.wanted?@(isfinite(rate)&&rate>0?rate:1):@0;
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate]=@1;
    info[MPMediaItemPropertyArtwork]=self.artwork?:self.placeholder;
    BOOL before=LXNPWriting;LXNPWriting=YES;
    if(![self.publishedInfo isEqualToDictionary:info]) { MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=info;self.publishedInfo=[info copy]; }
    MPNowPlayingInfoCenter.defaultCenter.playbackState=self.wanted?MPNowPlayingPlaybackStatePlaying:MPNowPlayingPlaybackStatePaused;
    if(!self.receivingRemote) { [UIApplication.sharedApplication beginReceivingRemoteControlEvents];self.receivingRemote=YES; }
    LXNPWriting=before;self.presentedKey=self.targetKey;self.presentedGeneration=self.generation;[self updateControls];
}
- (void)finishArtwork:(MPMediaItemArtwork *)artwork epoch:(NSUInteger)epoch {
    if(epoch!=self.coverEpoch || !self.snapshot.count)return;
    self.coverTask=nil;self.artwork=artwork?:self.placeholder;
    if(artwork)[self.covers setObject:artwork forKey:self.coverPath cost:512*512*4];
    // Prefetch while resolving, but do not put the next album's cover on the
    // previous song's retained card.
    if(self.generation==self.presentedGeneration && [self.targetKey isEqualToString:self.presentedKey])[self publish];
}
- (MPMediaItemArtwork *)decodeArtwork:(NSData *)data {
    if(!data.length || data.length>8*1024*1024)return nil;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!source)return nil;
    NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@512,(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES};
    CGImageRef cg=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);CFRelease(source);if(!cg)return nil;
    UIImage *image=[UIImage imageWithCGImage:cg];CGImageRelease(cg);
    return [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size){return image;}];
}
- (void)fetchArtwork:(NSString *)path epoch:(NSUInteger)epoch {
    NSURL *url=[NSURL URLWithString:path];
    if(![url.scheme.lowercaseString isEqual:@"http"] && ![url.scheme.lowercaseString isEqual:@"https"]) {
        NSString *file=url.isFileURL?url.path:path;
        __weak LXNowPlayingCoordinator *weak=self;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            MPMediaItemArtwork *artwork=[weak decodeArtwork:[NSData dataWithContentsOfFile:file]];
            LXNPMain(^{[weak finishArtwork:artwork epoch:epoch];});
        });return;
    }
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.timeoutInterval=12;
    __weak LXNowPlayingCoordinator *weak=self;
    self.coverTask=[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        LXNowPlayingCoordinator *owner=weak;MPMediaItemArtwork *artwork=error?nil:[owner decodeArtwork:data];
        LXNPMain(^{[weak finishArtwork:artwork epoch:epoch];});
    }];[self.coverTask resume];
}
- (void)clear {
    [self.coverTask cancel];self.coverTask=nil;self.coverEpoch++;self.snapshot=nil;self.publishedInfo=nil;self.targetKey=nil;self.presentedKey=nil;self.coverPath=nil;self.artwork=nil;self.generation=-1;
    atomic_store(&LXNPOwned,false);BOOL before=LXNPWriting;LXNPWriting=YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;MPNowPlayingInfoCenter.defaultCenter.playbackState=MPNowPlayingPlaybackStateStopped;
    [self updateControls];
    if(self.receivingRemote) { [UIApplication.sharedApplication endReceivingRemoteControlEvents];self.receivingRemote=NO; }
    LXNPWriting=before;
}
@end

#ifndef LX_CARPLAY_TESTING
__attribute__((constructor))
#endif
static void LXOwnInstallNowPlaying(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        LXNPOriginalInfo=LXNPHook(MPNowPlayingInfoCenter.class,@selector(setNowPlayingInfo:),(IMP)LXNPLegacyInfo);
        LXNPOriginalState=LXNPHook(MPNowPlayingInfoCenter.class,@selector(setPlaybackState:),(IMP)LXNPLegacyState);
        LXNPOriginalEnabled=LXNPHook(MPRemoteCommand.class,@selector(setEnabled:),(IMP)LXNPLegacyEnabled);
        LXNPOriginalEnd=LXNPHook(UIApplication.class,@selector(endReceivingRemoteControlEvents),(IMP)LXNPLegacyEnd);
        NSNotificationCenter *notes=NSNotificationCenter.defaultCenter;
        [notes addObserverForName:@"LXOwnNowPlaying" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){[LXNowPlayingCoordinator.shared receive:note.userInfo?:@{}];}];
        [notes addObserverForName:@"LXOwnNowPlayingClear" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){[LXNowPlayingCoordinator.shared clear];}];
        [notes addObserverForName:@"LXOwnAudioReady" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){[LXNowPlayingCoordinator.shared installControls];}];
        [notes addObserverForName:@"LXOwnAudioRouteHold" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            LXNowPlayingCoordinator *owner=LXNowPlayingCoordinator.shared;owner.held=[note.userInfo[@"held"] boolValue];
            if(owner.held){NSMutableDictionary *paused=[owner.snapshot mutableCopy];paused[@"wanted"]=@NO;owner.snapshot=paused;[owner publish];}
        }];
    });
}
