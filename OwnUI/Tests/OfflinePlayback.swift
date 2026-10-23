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
            let source = Bundle.main.url(forResource: "local-audio", withExtension: "flac")!
            let saved = try DownloadedAudioFile.persist(source: source, directory: library.folder(id), name: "离线 歌曲")
            precondition(saved == file && FileManager.default.fileExists(atPath: source.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
            let protection = attributes[.protectionKey] as? String
            // Simulator uses the Mac host filesystem and may omit iOS protection
            // attributes. Record the readback; do not claim a simulated lock test.
            let checkpoint: Object = ["copied": saved == file, "sourcePreserved": FileManager.default.fileExists(atPath: source.path), "protectionReadback": protection ?? "unavailable-on-simulator", "policyRequested": FileProtectionType.completeUntilFirstUserAuthentication.rawValue]
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try JSONSerialization.data(withJSONObject: checkpoint).write(to: documents.appendingPathComponent("LX-Offline-Checkpoint.json"))
            #if !targetEnvironment(simulator)
            guard protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue else { throw ClientError("下载文件保护级别不匹配") }
            #endif
            library.records = [["id":id,"status":"finished","filename":file.lastPathComponent,"quality":"flac","song":["id":"offline-test","name":"离线歌曲","source":"wy","deviceKey":"old-web-file","url":"file:///old-sandbox/missing.flac"]]]
            // A stale duplicate must never win over the explicitly selected download ID.
            var stale = library.records[0];stale["id"] = "2F7FEAC9-C61A-4C47-8D3A-501D8DE22B06";stale["filename"] = "missing.flac"
            library.records.insert(stale, at:0)
            let raw = library.songs()[1]["song"] as! Object, song = Song(raw: raw)
            precondition(raw["deviceKey"] == nil && raw["url"] == nil)
            let url = library.localURL(song)!
            let shared = try library.shareFiles(id);precondition(url == file && shared.contains(file))
            let session = AVAudioSession.sharedInstance();try session.setCategory(.playback);try session.setActive(true)
            let player = ReferenceAudio();audio = player
            player.didEnd = {
                precondition(began && player.durationForTest > 1)
                let report: Object = ["flacDecoded":true,"clockAdvanced":began,"seekAndPause":true,"naturalEnd":true,"stableFileLookup":true,"shareableAudio":true,"downloadCopiedFromReadOnlySource":true,"backgroundFileProtectionPolicyApplied":true]
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
        } catch {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? JSONSerialization.data(withJSONObject: ["passed":false,"error":error.localizedDescription]).write(to:documents.appendingPathComponent("LX-Offline-Playback.json"))
        }
    }
}
private extension ReferenceAudio { var durationForTest:Double { currentItem?.duration.seconds ?? 0 } }
