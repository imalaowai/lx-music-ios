#if DEBUG
import UIKit
import Foundation

/// Simulator-only regression: actual AVPlayer EOF transitions and offline sidecars.
/// No test audio or launch hook is compiled into the release IPA.
enum PlaybackSmoke {
    static var started = false
    static var timer: Timer?
    static func result(_ value: String) {
        timer?.invalidate(); timer = nil
        if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            try? Data(value.utf8).write(to: root.appendingPathComponent("PlaybackSmokeReady"), options: .atomic)
        }
    }
    static func start() {
        guard !started else { return }; started = true
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("LXPlaybackSmoke", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var urls: [URL] = []
            for index in 0..<8 {
                let url = root.appendingPathComponent("Track-\(index).wav")
                var wave = Data()
                func ascii(_ value: String) { wave.append(contentsOf: value.utf8) }
                func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
                func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
                let samples: UInt32 = 44100, bytes = samples * 2
                ascii("RIFF"); u32(36 + bytes); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16); ascii("data"); u32(bytes); wave.append(Data(count: Int(bytes)))
                try wave.write(to: url); urls.append(url)
            }
            let lyric = root.appendingPathComponent("Track-0.lrc")
            try "[00:00.00]Offline fixture".write(to: lyric, atomically: true, encoding: .utf8); urls.append(lyric)
            let cover = root.appendingPathComponent("Track-0.jpg")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in UIColor.systemPink.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
            try image.jpegData(compressionQuality: 0.8)!.write(to: cover); urls.append(cover)
            MusicLibrary.shared.importFiles(urls) { value in
                do {
                    guard try value.get() == 8 else { throw ClientError("Offline import count mismatch") }
                    let rows = MusicLibrary.shared.songs().filter { text(($0["song"] as? Object)?["name"]).hasPrefix("Track-") }
                    let songs = rows.compactMap { $0["song"] as? Object }.sorted { text($0["name"]) < text($1["name"]) }.map { Song(raw: $0) }
                    guard songs.count == 8, let first = songs.first else { throw ClientError("Offline list mismatch") }
                    let id = text(first.raw["offlineId"])
                    guard text(try MusicLibrary.shared.assets(id)["lyric"]).contains("Offline fixture"), try MusicLibrary.shared.shareFiles(id).count == 3 else { throw ClientError("Offline cover, lyrics or share files missing") }
                    let player = Player.shared; player.mode = "order"; player.select(songs, index: 0, user: false)
                    var visited = Set<Int>()
                    let deadline = Date().addingTimeInterval(50)
                    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        visited.insert(player.index)
                        if !player.failure.isEmpty { result("failed: " + player.failure); return }
                        if visited.count == 8 && player.index == 7 && !player.wanted && player.position > 0.8 && !bool(player.snapshot()["playing"]) { result("ready"); return }
                        if Date() > deadline { result("failed: indices=\(visited.sorted()), index=\(player.index), wanted=\(player.wanted), position=\(player.position), duration=\(player.duration)") }
                    }
                } catch { result("failed: " + error.localizedDescription) }
            }
        } catch { result("failed: " + error.localizedDescription) }
    }
}
#endif
