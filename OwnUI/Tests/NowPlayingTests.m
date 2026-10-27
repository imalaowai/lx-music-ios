// Import after LXNowPlayingCoordinator.m; execute the actual production owner,
// real InfoCenter setters and real remote-command availability in Simulator.
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
    check(commands.nextTrackCommand.enabled && commands.previousTrackCommand.enabled && !commands.skipForwardCommand.enabled,@"nativeTransportKeepsTrackButtonsWithoutGlobalCommandHooks");
    NSDictionary *before=[center.nowPlayingInfo copy];
    NSMutableDictionary *b=[a mutableCopy];b[@"songId"]=@"B";b[@"title"]=@"B";b[@"generation"]=@2;b[@"loading"]=@YES;b[@"duration"]=@0;b[@"playbackRate"]=@0;
    [owner receive:b];
    check([center.nowPlayingInfo[titleKey] isEqual:@"A"] &&
          [center.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue]==[before[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] &&
          [center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.pauseCommand.enabled,
          @"resolvingNextTrackKeepsCompleteCardButFreezesOldProgressClock");
    b[@"loading"]=@NO;b[@"duration"]=@240;b[@"playbackRate"]=@1;b[@"elapsedTime"]=@0;[owner receive:b];
    check([center.nowPlayingInfo[titleKey] isEqual:@"B"] && [center.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] intValue]==240,@"readyTrackReplacesMetadataWithoutEmptyIntermediateCard");
    [owner receive:a];
    check([center.nowPlayingInfo[titleKey] isEqual:@"B"],@"staleGenerationCannotRestorePreviousSong");
    b[@"playbackRate"]=@0;b[@"loading"]=@YES;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.pauseCommand.enabled,@"bufferingFreezesLockScreenClockWithoutChangingPauseControls");
    b[@"loading"]=@NO;b[@"playbackRate"]=@1;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==1 && commands.pauseCommand.enabled,@"confirmedPlaybackResumesLockScreenClock");
    b[@"interrupted"]=@YES;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.playCommand.enabled,@"systemInterruptionStillShowsPausedControls");
    b[@"interrupted"]=@NO;
    b[@"wanted"]=@NO;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==0 && commands.playCommand.enabled && !commands.pauseCommand.enabled && commands.nextTrackCommand.enabled,@"realPauseRemainsVisibleAndKeepsTrackButtons");
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
    check([center.nowPlayingInfo isEqualToDictionary:retained] && [center.nowPlayingInfo[rateKey] doubleValue]==0,
          @"prefetchedNextCoverCannotAppearAndOldClockStaysFrozenDuringTransition");
    c[@"loading"]=@NO;[owner receive:c];
    check(center.nowPlayingInfo[MPMediaItemPropertyArtwork]!=nil,@"missingArtworkUsesStableMusicPlaceholder");
    NSDictionary *complete=[center.nowPlayingInfo copy];c[@"generation"]=@4;c[@"loading"]=@YES;c[@"duration"]=@0;c[@"elapsedTime"]=@0;[owner receive:c];
    check([center.nowPlayingInfo[titleKey] isEqual:@"C"] &&
          [center.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue]==[complete[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] &&
          [center.nowPlayingInfo[rateKey] doubleValue]==0,
          @"repeatingSameTrackRetainsCardAndFreezesProgressUntilReady");
    __block NSDictionary *remote;id observer=[NSNotificationCenter.defaultCenter addObserverForName:@"LXOwnRemoteCommand" object:nil queue:nil usingBlock:^(NSNotification *note){remote=note.userInfo;}];
    LXOwnDeliverRemoteCommand(@"next",nil,NSProcessInfo.processInfo.systemUptime);[NSNotificationCenter.defaultCenter removeObserver:observer];
    check([remote[@"command"] isEqual:@"next"] && [remote[@"eventAt"] doubleValue]>0,@"nativeRemoteButtonsDeliverTimestampedCommandsWithoutJavaScript");
    [owner clear];
    check(center.nowPlayingInfo==nil && !commands.nextTrackCommand.enabled && !commands.playCommand.enabled,@"genuineClearStillReleasesLockScreenAndCommands");
}
