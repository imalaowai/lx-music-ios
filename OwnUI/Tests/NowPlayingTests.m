// Import after LXNowPlayingCoordinator.m; execute the actual production owner,
// real InfoCenter setters and real remote-command availability in Simulator.
static void LXRunNowPlayingTests(void (^check)(BOOL,NSString *)) {
    LXOwnInstallNowPlaying();
    LXNowPlayingCoordinator *owner=LXNowPlayingCoordinator.shared;[owner clear];
    NSString *titleKey=MPMediaItemPropertyTitle,*rateKey=MPNowPlayingInfoPropertyPlaybackRate;
    NSDictionary *a=@{@"songId":@"A",@"generation":@1,@"title":@"A",@"wanted":@YES,@"loading":@NO,@"playbackRate":@1,@"duration":@180,@"elapsedTime":@30,@"artwork":@""};
    [owner receive:a];
    MPNowPlayingInfoCenter *center=MPNowPlayingInfoCenter.defaultCenter;MPRemoteCommandCenter *commands=MPRemoteCommandCenter.sharedCommandCenter;
    check([center.nowPlayingInfo[titleKey] isEqual:@"A"] && center.nowPlayingInfo[MPMediaItemPropertyArtwork]!=nil,@"nativeMetadataPublishesWithoutJavaScript");
    center.nowPlayingInfo=nil;center.playbackState=MPNowPlayingPlaybackStateStopped;
    commands.nextTrackCommand.enabled=NO;commands.previousTrackCommand.enabled=NO;commands.skipForwardCommand.enabled=YES;
    [UIApplication.sharedApplication endReceivingRemoteControlEvents];
    check([center.nowPlayingInfo[titleKey] isEqual:@"A"] && [center.nowPlayingInfo[rateKey] doubleValue]==1,@"legacyResetCannotClearOwnedLockScreenCard");
    check(commands.nextTrackCommand.enabled && commands.previousTrackCommand.enabled && !commands.skipForwardCommand.enabled,@"legacyResetCannotDisableTrackButtonsOrRestoreSkipButtons");
    center.nowPlayingInfo=@{titleKey:@"late legacy song"};
    check([center.nowPlayingInfo[titleKey] isEqual:@"A"],@"legacyMetadataCannotOverwriteCurrentSong");
    NSDictionary *before=[center.nowPlayingInfo copy];
    NSMutableDictionary *b=[a mutableCopy];b[@"songId"]=@"B";b[@"title"]=@"B";b[@"generation"]=@2;b[@"loading"]=@YES;b[@"duration"]=@0;b[@"playbackRate"]=@0;
    [owner receive:b];
    check([center.nowPlayingInfo isEqualToDictionary:before] && commands.pauseCommand.enabled,@"resolvingNextTrackKeepsCompleteCardAndPauseButton");
    b[@"loading"]=@NO;b[@"duration"]=@240;b[@"playbackRate"]=@1;b[@"elapsedTime"]=@0;[owner receive:b];
    check([center.nowPlayingInfo[titleKey] isEqual:@"B"] && [center.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] intValue]==240,@"readyTrackReplacesMetadataWithoutEmptyIntermediateCard");
    [owner receive:a];
    check([center.nowPlayingInfo[titleKey] isEqual:@"B"],@"staleGenerationCannotRestorePreviousSong");
    b[@"playbackRate"]=@0;b[@"loading"]=@YES;[owner receive:b];
    check([center.nowPlayingInfo[rateKey] doubleValue]==1 && commands.pauseCommand.enabled,@"bufferingDoesNotTransientlyDisplayPausedControls");
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
    check([center.nowPlayingInfo isEqualToDictionary:retained],@"prefetchedNextCoverCannotAppearOnRetainedPreviousSong");
    c[@"loading"]=@NO;[owner receive:c];
    check(center.nowPlayingInfo[MPMediaItemPropertyArtwork]!=nil,@"missingArtworkUsesStableMusicPlaceholder");
    NSDictionary *complete=[center.nowPlayingInfo copy];c[@"generation"]=@4;c[@"loading"]=@YES;c[@"duration"]=@0;c[@"elapsedTime"]=@0;[owner receive:c];
    check([center.nowPlayingInfo isEqualToDictionary:complete],@"repeatingSameTrackAlsoRetainsCompleteCardUntilReady");
    __block NSDictionary *remote;id observer=[NSNotificationCenter.defaultCenter addObserverForName:@"LXOwnRemoteCommand" object:nil queue:nil usingBlock:^(NSNotification *note){remote=note.userInfo;}];
    LXNPSendRemote(@"next",nil);[NSNotificationCenter.defaultCenter removeObserver:observer];
    check([remote[@"command"] isEqual:@"next"] && [remote[@"eventAt"] doubleValue]>0,@"nativeRemoteButtonsDeliverTimestampedCommandsWithoutJavaScript");
    [owner clear];
    check(center.nowPlayingInfo==nil && !commands.nextTrackCommand.enabled && !commands.playCommand.enabled,@"genuineClearStillReleasesLockScreenAndCommands");
}
