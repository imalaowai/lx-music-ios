import Foundation
import AVFoundation

// Uses the production file lookup and production AVAudioPlayer path with a real
// FLAC fixture, including a Chinese filename, playback clock, seek and natural EOF.
enum OfflinePlayback {
    static var audio: ReferenceAudio?
    static var began = false
    static func start() {
        do {
            let id = "B86B78E5-25E2-4986-A387-0FD79074211F", library = MusicLibrary.shared
            let file = try library.folder(id).appendingPathComponent("离线 歌曲.flac")
            try Data(contentsOf: Bundle.main.url(forResource: "local-audio", withExtension: "flac")!).write(to: file)
            library.records = [["id":id,"status":"finished","filename":file.lastPathComponent,"quality":"flac","song":["id":"offline-test","name":"离线歌曲","source":"wy","deviceKey":"old-web-file","url":"file:///old-sandbox/missing.flac"]]]
            let raw = library.songs()[0]["song"] as! Object, song = Song(raw: raw)
            precondition(raw["deviceKey"] == nil && raw["url"] == nil)
            let url = library.localURL(song)!
            let shared = try library.shareFiles(id);precondition(url == file && shared.contains(file))
            let session = AVAudioSession.sharedInstance();try session.setCategory(.playback);try session.setActive(true)
            let player = ReferenceAudio();audio = player
            player.didEnd = {
                precondition(began && player.durationForTest > 1)
                let report: Object = ["flacDecoded":true,"clockAdvanced":began,"seekAndPause":true,"naturalEnd":true,"stableFileLookup":true,"shareableAudio":true]
                let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
                try! JSONSerialization.data(withJSONObject:report).write(to:root.appendingPathComponent("LX-Offline-Playback.json"))
                audio = nil
            }
            player.load(url,song:song,quality:"flac",position:0,paused:true) { result in
                guard case .success = result else { fatalError("Native offline FLAC did not load: \(result)") }
                player.play()
                DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                    began = player.currentTime().seconds > 0.08;precondition(began)
                    player.pause();let paused = player.currentTime().seconds
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                        precondition(abs(player.currentTime().seconds-paused)<0.03)
                        player.seek(to:CMTime(seconds:1,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero) { ok in
                            precondition(ok && player.currentTime().seconds>0.9);player.play()
                        }
                    }
                }
            }
        } catch { fatalError("Offline playback check failed: \(error)") }
    }
}
private extension ReferenceAudio { var durationForTest:Double { currentItem?.duration.seconds ?? 0 } }
