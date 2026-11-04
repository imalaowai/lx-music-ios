// Import after LXNowPlayingCoordinator.m; execute the actual production owner,
// real InfoCenter setters and real remote-command availability in Simulator.
@interface LXFixturePositionEvent:MPChangePlaybackPositionCommandEvent
@property(nonatomic) double fixturePosition;
@end
@implementation LXFixturePositionEvent
- (NSTimeInterval)positionTime { return self.fixturePosition; }
@end
static void LXRunNowPlayingTests(void (^check)(BOOL,NSString *)) {
    LXOwnInstallNowPlaying();
    LXNowPlayingCoordinator *owner=LXNowPlayingCoordinator.shared;[owner clear];
    [owner installControls];
    [owner receive:@{@"songId":@"restored",@"generation":@0,@"title":@"播放历史",@"wanted":@NO,@"loading":@NO}];
    check(!atomic_load(&LXNPOwned) && !owner.controlsInstalled && !owner.placeholder && !owner.publishedInfo,@"restoredPausedQueueDoesNotInitializeMediaServices");
    [owner enqueue:@{@"songId":@"pending",@"generation":@0,@"wanted":@YES,@"loading":@YES} clear:NO];
    check(!atomic_load(&LXNPOwned) && owner.pendingSnapshot!=nil,@"metadataNotificationsDoNotPerformSynchronousMediaWork");
    [owner flush];[owner clear];
    NSString *titleKey=MPMediaItemPropertyTitle,*rateKey=MPNowPlayingInfoPropertyPlaybackRate;
    NSDictionary *a=@{@"songId":@"A",@"generation":@1,@"title":@"A",@"wanted":@YES,@"loading":@NO,@"playbackRate":@1,@"duration":@180,@"elapsedTime":@30,@"artwork":@""};
    [owner receive:a];
    MPNowPlayingInfoCenter *center=MPNowPlayingInfoCenter.defaultCenter;MPRemoteCommandCenter *commands=MPRemoteCommandCenter.sharedCommandCenter;
    check([center.nowPlayingInfo[titleKey] isEqual:@"A"] && center.nowPlayingInfo[MPMediaItemPropertyArtwork]!=nil,@"nativeMetadataPublishesWithoutJavaScript");
    check(commands.nextTrackCommand.enabled && commands.previousTrackCommand.enabled &&
          owner.remoteTargets[@"next"]!=nil && owner.remoteTargets[@"previous"]!=nil && !commands.skipForwardCommand.enabled,
          @"nativeTransportRegistersDirectNextAndPreviousHandlers");
    check(commands.playCommand.enabled && commands.pauseCommand.enabled && commands.togglePlayPauseCommand.enabled &&
          owner.remoteTargets[@"play"]!=nil && owner.remoteTargets[@"pause"]!=nil && owner.remoteTargets[@"toggle"]!=nil &&
          owner.remoteTargets[@"stop"]!=nil && owner.remoteTargets[@"seek"]!=nil,
          @"allNativeTransportTargetsExistAndPlayPauseToggleAreAvailable");
    NSDictionary *targets=[owner.remoteTargets copy];[owner installControls];[owner installControls];
    check(owner.remoteTargets.count==7 && [owner.remoteTargets isEqualToDictionary:targets],@"repeatedAudioReadinessDoesNotDuplicateRemoteTargets");
    NSDictionary *before=[center.nowPlayingInfo copy];
    NSMutableDictionary *b=[a mutableCopy];b[@"songId"]=@"B";b[@"title"]=@"B";b[@"generation"]=@2;b[@"loading"]=@YES;b[@"duration"]=@0;b[@"playbackRate"]=@0;
    [owner receive:b];
    // Simulate a competing native owner changing the enabled flags during the
    // transition. The coordinator must repair them even when wanted is unchanged.
    commands.playCommand.enabled=NO;commands.pauseCommand.enabled=NO;
    commands.nextTrackCommand.enabled=NO;commands.previousTrackCommand.enabled=NO;
    [owner receive:b];
    check([center.nowPlayingInfo[titleKey] isEqual:@"A"] &&
          [center.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue]==[before[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] &&
          [center.nowPlayingInfo[rateKey] doubleValue]>0 && [center.nowPlayingInfo[rateKey] doubleValue]<0.02 &&
          commands.playCommand.enabled && commands.pauseCommand.enabled && commands.togglePlayPauseCommand.enabled && commands.nextTrackCommand.enabled && commands.previousTrackCommand.enabled,
          @"resolvingNextTrackKeepsCompleteCardAndRepairsActiveRemoteControls");
    b[@"loading"]=@NO;b[@"duration"]=@240;b[@"playbackRate"]=@1;b[@"elapsedTime"]=@0;[owner receive:b];
    check([center.nowPlayingInfo[titleKey] isEqual:@"B"] && [center.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] intValue]==240,@"readyTrackReplacesMetadataWithoutEmptyIntermediateCard");
    [owner receive:a];
    check([center.nowPlayingInfo[titleKey] isEqual:@"B"],@"staleGenerationCannotRestorePreviousSong");
    b[@"playbackRate"]=@0;b[@"loading"]=@YES;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.playCommand.enabled && commands.pauseCommand.enabled && commands.togglePlayPauseCommand.enabled,@"bufferingCannotGreyAnySystemPlayPauseVariant");
    b[@"loading"]=@NO;b[@"playbackRate"]=@1;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==1 && commands.pauseCommand.enabled,@"confirmedPlaybackResumesLockScreenClock");
    b[@"interrupted"]=@YES;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.playCommand.enabled,@"systemInterruptionStillShowsPausedControls");
    b[@"interrupted"]=@NO;
    b[@"wanted"]=@NO;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.playCommand.enabled && commands.pauseCommand.enabled && commands.togglePlayPauseCommand.enabled && commands.nextTrackCommand.enabled,@"realPauseRemainsVisibleAndKeepsTrackButtons");
    b[@"wanted"]=@YES;b[@"loading"]=@NO;b[@"playbackRate"]=@1;[owner receive:b];
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioRouteHold" object:nil userInfo:@{@"held":@YES}];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.playCommand.enabled,@"bluetoothOutputLossStillImmediatelyPausesLockScreenState");
    [NSNotificationCenter.defaultCenter postNotificationName:@"LXOwnAudioRouteHold" object:nil userInfo:@{@"held":@NO}];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0,@"releasingRouteHoldDoesNotAutoplayLockScreenState");
    [owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==1,@"explicitPlaybackRestoresNativeControlsAfterRouteHold");
    // Cover callbacks from an old generation may finish after the next song.
    NSUInteger old=owner.coverEpoch;owner.coverEpoch++;
    MPMediaItemArtwork *kept=owner.artwork;[owner finishArtwork:owner.placeholder epoch:old];
    check(owner.artwork==kept,@"staleArtworkCompletionCannotReplaceNewTrackCover");
    NSMutableDictionary *c=[b mutableCopy];c[@"songId"]=@"C";c[@"title"]=@"C";c[@"generation"]=@3;c[@"loading"]=@YES;[owner receive:c];
    NSDictionary *retained=[center.nowPlayingInfo copy];[owner finishArtwork:owner.placeholder epoch:owner.coverEpoch];
    check([center.nowPlayingInfo isEqualToDictionary:retained] &&
          [center.nowPlayingInfo[rateKey] doubleValue]>0 && [center.nowPlayingInfo[rateKey] doubleValue]<0.02 &&
          commands.nextTrackCommand.enabled && commands.previousTrackCommand.enabled,
          @"prefetchedNextCoverCannotAppearAndRemoteControlsStayActiveDuringTransition");
    c[@"loading"]=@NO;[owner receive:c];
    check(center.nowPlayingInfo[MPMediaItemPropertyArtwork]!=nil,@"missingArtworkUsesStableMusicPlaceholder");
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(96,96)];
    NSData *png=[renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *ctx){[UIColor.blueColor setFill];UIRectFill(CGRectMake(0,0,96,96));}];
    MPMediaItemArtwork *decoded=[owner decodeArtwork:png];
    check(decoded!=nil && [decoded imageWithSize:CGSizeMake(60,60)]!=nil && [owner decodeArtwork:[@"not an image" dataUsingEncoding:NSUTF8StringEncoding]]==nil,
          @"realCoverBytesDecodeIntoSystemRequestableArtworkAndRejectInvalidData");
    c[@"artwork"]=[@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];[owner receive:c];
    check(center.nowPlayingInfo[MPMediaItemPropertyArtwork]==owner.artwork && owner.artwork!=owner.placeholder,
          @"receivedCoverImageIsPublishedOnSystemLockScreenCard");
    NSUInteger coverEpoch=owner.coverEpoch;c[@"artworkResolved"]=@YES;[owner receive:c];
    check(owner.coverEpoch>coverEpoch,@"providerRefreshCanRetryTheSamePreviouslyFailedCoverAddress");
    NSMutableDictionary *erased=[center.nowPlayingInfo mutableCopy];[erased removeObjectForKey:MPMediaItemPropertyArtwork];center.nowPlayingInfo=erased;
    [owner receive:c];
    check(center.nowPlayingInfo[MPMediaItemPropertyArtwork]==owner.artwork,@"lateLegacyMetadataWriteCannotPermanentlyEraseLockScreenCover");
    NSDictionary *complete=[center.nowPlayingInfo copy];c[@"generation"]=@4;c[@"loading"]=@YES;c[@"duration"]=@0;c[@"elapsedTime"]=@0;[owner receive:c];
    check([center.nowPlayingInfo[titleKey] isEqual:@"C"] &&
          [center.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue]==[complete[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] &&
          [center.nowPlayingInfo[rateKey] doubleValue]>0 && [center.nowPlayingInfo[rateKey] doubleValue]<0.02 &&
          commands.nextTrackCommand.enabled && commands.previousTrackCommand.enabled,
          @"repeatingSameTrackRetainsCardAndRemoteControlsStayActiveUntilReady");
    __block NSMutableArray *remoteEvents=[NSMutableArray array];
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:@"LXOwnRemoteCommand" object:nil queue:nil usingBlock:^(NSNotification *note){[remoteEvents addObject:note.userInfo?:@{}];}];
    MPRemoteCommandHandlerStatus nextStatus=[owner.remoteTargets[@"next"] invoke:nil];
    MPRemoteCommandHandlerStatus previousStatus=[owner.remoteTargets[@"previous"] invoke:nil];
    BOOL transportOK=YES;
    for(NSString *command in @[@"pause",@"play",@"toggle",@"stop"]) {
        transportOK=transportOK && [owner.remoteTargets[command] invoke:nil]==MPRemoteCommandHandlerStatusSuccess;
    }
    // Apple exposes no public initializer for this readonly event. Allocate a
    // test subclass whose only accessed property is the overridden positionTime.
    LXFixturePositionEvent *seek=class_createInstance(LXFixturePositionEvent.class,0);seek.fixturePosition=42;
    transportOK=transportOK && [owner.remoteTargets[@"seek"] invoke:seek]==MPRemoteCommandHandlerStatusSuccess;
    seek.fixturePosition=NAN;
    BOOL invalidRejected=[owner.remoteTargets[@"seek"] invoke:seek]==MPRemoteCommandHandlerStatusCommandFailed &&
                         [owner.remoteTargets[@"seek"] invoke:nil]==MPRemoteCommandHandlerStatusCommandFailed;
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    check(nextStatus==MPRemoteCommandHandlerStatusSuccess && previousStatus==MPRemoteCommandHandlerStatusSuccess &&
          [remoteEvents count]==7 && [remoteEvents[0][@"command"] isEqual:@"next"] &&
          [remoteEvents[1][@"command"] isEqual:@"previous"] && [remoteEvents[0][@"eventAt"] doubleValue]>0 &&
          [remoteEvents[1][@"eventAt"] doubleValue]>0,
          @"nativeNextAndPreviousHandlersDeliverTimestampedCommandsWithoutJavaScript");
    check(transportOK && invalidRejected && [remoteEvents[2][@"command"] isEqual:@"pause"] &&
          [remoteEvents[3][@"command"] isEqual:@"play"] && [remoteEvents[4][@"command"] isEqual:@"toggle"] &&
          [remoteEvents[5][@"command"] isEqual:@"stop"] && [remoteEvents[6][@"command"] isEqual:@"seek"] &&
          [remoteEvents[6][@"position"] doubleValue]==42 && [remoteEvents[4][@"eventAt"] doubleValue]>0,
          @"registeredNativePlayPauseToggleStopAndSeekTargetsDeliverExactlyOneCommandWithoutJavaScript");
    LXNativeRemoteTarget *oldPlay=owner.remoteTargets[@"play"];
    [owner clear];
    check(center.nowPlayingInfo==nil && !commands.nextTrackCommand.enabled && !commands.previousTrackCommand.enabled &&
          owner.remoteTargets.count==0 && !commands.playCommand.enabled,
          @"genuineClearReleasesOnlyOwnedLockScreenTargetsAndCommands");
    check([oldPlay invoke:nil]==MPRemoteCommandHandlerStatusCommandFailed && !commands.togglePlayPauseCommand.enabled,
          @"releasedSessionCannotAcceptLatePlayCommands");
}
