import Foundation
import AVFoundation

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
    }
    static func start() {
        let player=Player.shared
        let raw:Object=["id":"offline-test","name":"本机断开测试","source":"wy","offlineId":"B86B78E5-25E2-4986-A387-0FD79074211F"]
        player.room.disconnect(clear:true);player.select([Song(raw:raw)],index:0)
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12) {
            do {
                try record(player.wanted && player.audio.localAudio?.isPlaying == true,"realLocalAudioStarted")
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
                player.play()
                try record(!player.routeGate.held && player.wanted && player.audio.localAudio?.isPlaying == true,"explicitPlayResumesActualAudio")
                try record(player.room.order.pendingID.isEmpty && player.room.outgoing.isEmpty,"localRejoinDoesNotRestartRoomTrack")
                NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.began.rawValue])
                NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:AVAudioSession.InterruptionType.ended.rawValue,AVAudioSessionInterruptionOptionKey:0])
                try record(!player.interrupted && !player.wanted && player.audio.localAudio?.isPlaying == false,"interruptionWithoutResumeOptionStaysPaused")
                player.room.disconnect(clear:true);player.pause(user:false);player.failure=""
                finish()
            } catch { finish(error) }
        }
    }
}
