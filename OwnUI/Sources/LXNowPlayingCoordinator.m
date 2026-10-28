#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <ImageIO/ImageIO.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <math.h>

// Own only this player's metadata. Do not swizzle UIKit/MediaPlayer classes:
// their initialization and private queues must remain independent of browsing.
static atomic_bool LXNPOwned=false;
static void LXNPMain(void (^action)(void)) { if(NSThread.isMainThread)action();else dispatch_async(dispatch_get_main_queue(),action); }
void LXOwnDeliverRemoteCommand(NSString *command,NSNumber *position,NSTimeInterval eventAt) {
    if(!atomic_load(&LXNPOwned))return;
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
@property(nonatomic,strong) id nextTrackTarget;
@property(nonatomic,strong) id previousTrackTarget;
@property(nonatomic) BOOL receivingRemote;
@property(nonatomic) NSInteger lastPlaybackState;
@property(nonatomic,strong) NSDictionary *pendingSnapshot;
@property(nonatomic) BOOL pendingClear;
@property(nonatomic) BOOL flushScheduled;
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
        _lastPlaybackState=-1;
    }return self;
}
- (BOOL)wanted { return [self.snapshot[@"wanted"] boolValue] && ![self.snapshot[@"interrupted"] boolValue] && !self.held; }
- (MPRemoteCommandHandlerStatus)handleNativeTrackCommand:(NSString *)command {
    if(!atomic_load(&LXNPOwned))return MPRemoteCommandHandlerStatusCommandFailed;
    LXOwnDeliverRemoteCommand(command,nil,NSProcessInfo.processInfo.systemUptime);
    return MPRemoteCommandHandlerStatusSuccess;
}
- (void)installControls {
    // Swift Player owns the song queue; TrackPlayer intentionally keeps only the active
    // decoder item and is configured without SkipToNext/SkipToPrevious capabilities.
    // These direct native targets are the single lock-screen track-skip path, even while
    // the RN JavaScript queue is asleep. Keep unrelated SDK targets intact.
    if(!atomic_load(&LXNPOwned))return;
    MPRemoteCommandCenter *center=MPRemoteCommandCenter.sharedCommandCenter;
    __weak LXNowPlayingCoordinator *weakSelf=self;
    if(!self.nextTrackTarget)self.nextTrackTarget=[center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event){
        return [weakSelf handleNativeTrackCommand:@"next"];
    }];
    if(!self.previousTrackTarget)self.previousTrackTarget=[center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event){
        return [weakSelf handleNativeTrackCommand:@"previous"];
    }];
    self.controlsInstalled=YES;[self updateControls];
}
- (void)updateControls {
    BOOL active=atomic_load(&LXNPOwned),wanted=self.wanted;
    MPRemoteCommandCenter *center=MPRemoteCommandCenter.sharedCommandCenter;
    // Another native owner or the system can change command availability while
    // Now Playing metadata is refreshed. Reassert the desired flags every time;
    // a cached wanted/paused signature is not proof that the flags still match.
    center.playCommand.enabled=active && !wanted;center.pauseCommand.enabled=active && wanted;
    center.stopCommand.enabled=active;center.togglePlayPauseCommand.enabled=NO;
    center.nextTrackCommand.enabled=active;center.previousTrackCommand.enabled=active;center.changePlaybackPositionCommand.enabled=active;
    center.skipForwardCommand.enabled=NO;center.skipBackwardCommand.enabled=NO;center.seekForwardCommand.enabled=NO;center.seekBackwardCommand.enabled=NO;
}
- (void)enqueue:(NSDictionary *)value clear:(BOOL)clear {
    self.pendingSnapshot=[value copy];self.pendingClear=clear;
    if(self.flushScheduled)return;self.flushScheduled=YES;
    dispatch_async(dispatch_get_main_queue(),^{[self flush];});
}
- (void)flush {
    if(!self.flushScheduled)return;self.flushScheduled=NO;
    NSDictionary *value=self.pendingSnapshot;BOOL clear=self.pendingClear;
    self.pendingSnapshot=nil;self.pendingClear=NO;
    if(clear)[self clear];else if(value)[self receive:value];
}
- (MPMediaItemArtwork *)defaultArtwork {
    if(self.placeholder)return self.placeholder;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(256,256)];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
        [[UIColor colorWithRed:0.12 green:0.25 blue:0.27 alpha:1] setFill];UIRectFill(CGRectMake(0,0,256,256));
        UIImage *note=[[UIImage systemImageNamed:@"music.note"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        [note drawInRect:CGRectMake(80,64,96,128)];
    }];
    self.placeholder=[[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size){return image;}];
    return self.placeholder;
}
- (void)receive:(NSDictionary *)value {
    NSString *key=[value[@"songId"] isKindOfClass:NSString.class]?value[@"songId"]:@"";if(!key.length)return;
    NSInteger generation=[value[@"generation"] integerValue];if(generation<self.generation)return;
    self.generation=generation;self.snapshot=[value copy];self.targetKey=key;
    // Restoring a paused queue or reading a playlist must not initialize
    // MediaRemote, render artwork, or acquire a lock-screen session.
    if(!atomic_load(&LXNPOwned) && (!self.wanted || [value[@"loading"] boolValue]))return;
    atomic_store(&LXNPOwned,true);
    if(!self.controlsInstalled)[self installControls];
    NSString *path=[value[@"artwork"] isKindOfClass:NSString.class]?value[@"artwork"]:@"";
    if(![self.coverPath isEqualToString:path]) {
        [self.coverTask cancel];self.coverTask=nil;self.coverPath=path;NSUInteger epoch=++self.coverEpoch;
        MPMediaItemArtwork *cached=[self.covers objectForKey:path];
        if(cached)self.artwork=cached;
        else if(!path.length)self.artwork=[self defaultArtwork];
        else [self fetchArtwork:path epoch:epoch];
    }
    [self publish];
}
- (void)publish {
    if(!self.snapshot.count || !atomic_load(&LXNPOwned))return;
    // A new stream may take time to resolve/open. Keep the last complete card
    // until the replacement is ready; actual pause/output loss always wins.
    if(self.wanted && [self.snapshot[@"loading"] boolValue] && self.publishedInfo.count && self.generation!=self.presentedGeneration) {
        // Retain the last complete card while the next track resolves, but freeze
        // its system playback clock. Otherwise iOS continues advancing the old
        // elapsed time at 1x even though the old decoder has already been paused;
        // when the new track arrives, the timeline visibly jumps back to zero.
        NSMutableDictionary *frozen=[self.publishedInfo mutableCopy];
        // Keep the Now Playing session in its active state so iOS continues routing lock-screen commands.
        // 0.01x is effectively stationary during a short track transition without publishing a paused session.
        frozen[MPNowPlayingInfoPropertyPlaybackRate]=@0.01;
        if(![self.publishedInfo isEqualToDictionary:frozen]) {
            MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=frozen;
            self.publishedInfo=[frozen copy];
        }
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
    double rate=[value[@"playbackRate"] doubleValue];
    // Playback intent controls the buttons, but must never manufacture clock
    // progress while the native decoder is paused or waiting for a sample.
    BOOL clockRunning=self.wanted && ![value[@"loading"] boolValue] && ![value[@"interrupted"] boolValue] && isfinite(rate) && rate>0;
    info[MPNowPlayingInfoPropertyPlaybackRate]=clockRunning?@(rate):@0;
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate]=@1;
    info[MPMediaItemPropertyArtwork]=self.artwork?:[self defaultArtwork];
    if(![self.publishedInfo isEqualToDictionary:info]) { MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=info;self.publishedInfo=[info copy]; }
    MPNowPlayingPlaybackState state=self.wanted?MPNowPlayingPlaybackStatePlaying:MPNowPlayingPlaybackStatePaused;
    if(self.lastPlaybackState!=state){MPNowPlayingInfoCenter.defaultCenter.playbackState=state;self.lastPlaybackState=state;}
    if(!self.receivingRemote) { [UIApplication.sharedApplication beginReceivingRemoteControlEvents];self.receivingRemote=YES; }
    self.presentedKey=self.targetKey;self.presentedGeneration=self.generation;[self updateControls];
}
- (void)finishArtwork:(MPMediaItemArtwork *)artwork epoch:(NSUInteger)epoch {
    if(epoch!=self.coverEpoch || !self.snapshot.count)return;
    self.coverTask=nil;self.artwork=artwork?:[self defaultArtwork];
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
    BOOL active=atomic_exchange(&LXNPOwned,false);
    if(!active && !self.receivingRemote && !self.controlsInstalled)return;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;MPNowPlayingInfoCenter.defaultCenter.playbackState=MPNowPlayingPlaybackStateStopped;
    [self updateControls];
    if(self.receivingRemote) { [UIApplication.sharedApplication endReceivingRemoteControlEvents];self.receivingRemote=NO; }
    MPRemoteCommandCenter *center=MPRemoteCommandCenter.sharedCommandCenter;
    if(self.nextTrackTarget){[center.nextTrackCommand removeTarget:self.nextTrackTarget];self.nextTrackTarget=nil;}
    if(self.previousTrackTarget){[center.previousTrackCommand removeTarget:self.previousTrackTarget];self.previousTrackTarget=nil;}
    self.controlsInstalled=NO;self.lastPlaybackState=-1;
}
@end

#ifndef LX_CARPLAY_TESTING
__attribute__((constructor))
#endif
static void LXOwnInstallNowPlaying(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        NSNotificationCenter *notes=NSNotificationCenter.defaultCenter;
        [notes addObserverForName:@"LXOwnNowPlaying" object:nil queue:nil usingBlock:^(NSNotification *note){NSDictionary *value=[note.userInfo copy]?:@{};dispatch_async(dispatch_get_main_queue(),^{[LXNowPlayingCoordinator.shared enqueue:value clear:NO];});}];
        [notes addObserverForName:@"LXOwnNowPlayingClear" object:nil queue:nil usingBlock:^(NSNotification *note){dispatch_async(dispatch_get_main_queue(),^{[LXNowPlayingCoordinator.shared enqueue:nil clear:YES];});}];
        [notes addObserverForName:@"LXOwnAudioReady" object:nil queue:nil usingBlock:^(NSNotification *note){dispatch_async(dispatch_get_main_queue(),^{[LXNowPlayingCoordinator.shared installControls];});}];
        [notes addObserverForName:@"LXOwnAudioRouteHold" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            LXNowPlayingCoordinator *owner=LXNowPlayingCoordinator.shared;owner.held=[note.userInfo[@"held"] boolValue];
            if(owner.held){NSMutableDictionary *paused=[owner.snapshot mutableCopy];paused[@"wanted"]=@NO;owner.snapshot=paused;[owner publish];}
        }];
    });
}
