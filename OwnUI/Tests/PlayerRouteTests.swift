import Foundation
import AVFoundation
import MediaPlayer
import UIKit

// Execute the production Player, RoomClient and route observer with real local
// FLAC playback. Bluetooth/CarPlay hardware itself is not simulated here.
enum PlayerRouteTests {
    static var results: Object = [:]
    static func record(_ pass: Bool, _ name: String) throws {
        results[name]=pass
        if !pass { throw ClientError(name) }
    }
    static func finish(_ error: Error? = nil) {
        if let error=error { results["passed"]=false;results["error"]=error.localizedDescription }
        else { results["passed"]=true }
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
        try? JSONSerialization.data(withJSONObject:results,options:.prettyPrinted).write(to:root.appendingPathComponent("LX-Player-Route-Checks.json"),options:.atomic)
        WebRecoveryTests.start()
    }
    static func waitForSystemArtwork(until deadline: TimeInterval, completion: @escaping (CGFloat) -> Void) {
        let artwork = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        let width = artwork?.bounds.width ?? 0
        if width == 32 || ProcessInfo.processInfo.systemUptime >= deadline { completion(width); return }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.04) { waitForSystemArtwork(until:deadline,completion:completion) }
    }
    static func start() {
        let player=Player.shared
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width:32,height:32), format:format).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x:0,y:0,width:32,height:32))
        }
        let cover = "data:image/png;base64," + image.pngData()!.base64EncodedString()
        let raw:Object=["id":"offline-test","name":"本机断开测试","source":"wy","offlineId":"B86B78E5-25E2-4986-A387-0FD79074211F",
                        "img":"data:image/png;base64,invalid","meta":["pic":cover]]
        let song = Song(raw:raw)
        player.room.disconnect(clear:true)
        player.room.afterInitialBinding {
            do {
                player.recent = [Song(raw:["id":"earlier","source":"wy"]), song]
                NotificationCenter.default.post(name:Notification.Name("LXOwnCarPlayAction"),object:nil,
                                                userInfo:["type":"play","listId":"__own_recent","musicId":song.playbackIdentity])
                let started = player.wanted && player.audio.localAudio?.isPlaying == true
                results["carPlayRecentActionStartsRealLocalAudio"] = started
                guard started else {
                    throw ClientError("Recent playback state: selected \(player.current?.key ?? ""), wanted \(player.wanted), loading \(player.loading), error \(player.failure)")
                }
                // EOF is covered by OfflinePlayback. Keep this short fixture
                // alive while the simulator's media service initializes.
                player.audio.localAudio?.numberOfLoops = -1
                waitForSystemArtwork(until:ProcessInfo.processInfo.systemUptime+3) { width in
                    verifyTransport(player, song: song, cover: cover, width: width)
                }
            } catch { finish(error) }
        }
    }
    static func verifyTransport(_ player: Player, song: Song, cover: String, width: CGFloat) {
        let raw = song.raw
        do {
            try record(player.recent.first?.key == "offline-test","actualDecoderPlaybackMovesSongToFrontOfRecentHistory")
            // Clear in-memory history and read it through the same entry point
            // used when CarPlay launches the process before the phone UI.
            player.recent.removeAll()
            player.restoreQueue()
            try record(player.recent.first?.key == "offline-test" && player.current?.key == "offline-test",
                       "recentHistoryIsPersistedForCarPlayColdStart")
            let metadata = NSMutableDictionary()
            NotificationCenter.default.post(name:Notification.Name("LXOwnNowPlayingDiagnostic"),object:metadata)
            guard width == 32 else {
                results["invalidFirstArtworkFallsBackToNestedCoverOnTheSystemCard"] = false
                throw ClientError("Artwork width \(width), native diagnostic \(metadata), fallback chosen \(player.nowPlayingArtwork(song) == cover)")
            }
            try record(true,"invalidFirstArtworkFallsBackToNestedCoverOnTheSystemCard")
            let index=player.index
            try record(LXOwnInvokeTransport("pause") && !player.wanted && player.audio.localAudio?.isPlaying == false,"registeredLockScreenPauseStopsActualLocalAudioWithoutJavaScript")
            try record(LXOwnInvokeTransport("play") && player.wanted && player.audio.localAudio?.isPlaying == true,"registeredLockScreenPlayResumesActualLocalAudioWithoutJavaScript")
            try record(LXOwnInvokeTransport("toggle") && !player.wanted && player.audio.localAudio?.isPlaying == false,"registeredHeadUnitTogglePausesActualLocalAudioOnce")
            try record(LXOwnInvokeTransport("toggle") && player.wanted && player.audio.localAudio?.isPlaying == true && player.index==index,"registeredHeadUnitToggleResumesActualLocalAudioOnceWithoutChangingTrack")
            try record(LXOwnInvokeTransport("stop") && !player.wanted && player.audio.localAudio?.isPlaying == false,"registeredStopPreservesResumableLocalTrack")
            _=LXOwnInvokeTransport("play")
            NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.began.rawValue])
            try record(player.interrupted && player.wanted && player.audio.localAudio?.isPlaying == false,"systemInterruptionPausesActualAudioWhileKeepingResumeIntent")
            NotificationCenter.default.post(name:AVAudioSession.routeChangeNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionRouteChangeReasonKey:AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            try record(player.routeGate.held && !player.wanted && player.audio.localAudio?.isPlaying == false,"outputLossPausesActualAudioAndHoldsPlayback")
            player.remote(["command":"play","eventAt":player.lastOutputLossAt-0.01])
            try record(player.routeGate.held && !player.wanted,"preDisconnectRemoteCommandCannotReleasePauseHold")
            NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.ended.rawValue,AVAudioSessionInterruptionOptionKey:AVAudioSession.InterruptionOptions.shouldResume.rawValue])
            player.play(user:false)
            NotificationCenter.default.post(name:AVAudioSession.routeChangeNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionRouteChangeReasonKey:AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
            try record(player.routeGate.held && !player.wanted && player.audio.localAudio?.isPlaying == false,"interruptionAndNewOutputDoNotAutoResume")
            player.room.binding=["roomId":"route-fixture"]
            let next:Object=["id":"B","name":"房间新歌曲","source":"wy"]
            player.room.apply(["revision":2,"playbackRevision":2,"reason":"track","song":next,"paused":false])
            try record(player.current?.key=="B" && !player.wanted && !player.loading && player.audio.currentItem==nil,"roomTracksFollowSilentlyWithoutResolvingOrPlaying")
            let quietGeneration=player.generation
            player.room.apply(["revision":2,"playbackRevision":2,"reason":"track","song":next,"paused":false])
            try record(player.generation==quietGeneration,"duplicateHeldRoomSnapshotsDoNotRebuildOrResolveAudio")
            player.room.apply(["revision":1,"reason":"track","song":raw,"paused":false])
            player.room.apply(["revision":2,"reason":"track","song":["id":"C","source":"wy"],"paused":false])
            try record(player.current?.key=="B","staleAndConflictingSameRevisionCannotRewindTrack")
            try record(player.room.outgoing.isEmpty && !player.room.sending && player.room.order.pendingID.isEmpty,"localOutputLossDoesNotSendRoomPause")
            player.room.apply(["revision":3,"playbackRevision":3,"reason":"track","song":raw,"paused":false,"currentTime":0,"updatedAt":Date().timeIntervalSince1970*1000])
            try record(LXOwnInvokeTransport("play"),"registeredSystemPlayRemainsUsableDuringOutputHold")
            try record(!player.routeGate.held && player.wanted && player.audio.localAudio?.isPlaying == true,"explicitPlayResumesActualAudio")
            try record(player.room.order.pendingID.isEmpty && player.room.outgoing.isEmpty,"localRejoinDoesNotRestartRoomTrack")
            NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.began.rawValue])
            NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.ended.rawValue,AVAudioSessionInterruptionOptionKey:0])
            try record(!player.interrupted && !player.wanted && player.audio.localAudio?.isPlaying == false,"interruptionWithoutResumeOptionStaysPaused")
            // Use an invalid sandbox path so no WebView file transfer remains
            // in flight when the separate page-recovery test starts.
            player.room.disconnect(clear:true)
            let remoteQueue=(0..<3).map{Song(raw:["id":"remote-\($0)","name":"Remote \($0)","source":"local",
                                                  "isLocal":true,"url":"file:///route-fixture/\($0).flac"])}
            player.queue=remoteQueue;player.index=0;player.mode="order";player.wanted=false;player.loading=false;player.failure=""
            let commandAt=ProcessInfo.processInfo.systemUptime
            player.remote(["command":"next","eventAt":commandAt])
            player.remote(["command":"next","eventAt":commandAt+0.01])
            try record(player.index==2,"rapidIntentionalNextCommandsAdvanceTwice")
            player.room.disconnect(clear:true);player.pause(user:false);player.failure=""
            finish()
        } catch { finish(error) }
    }
}
