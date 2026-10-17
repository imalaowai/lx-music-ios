import UIKit
import AVFoundation
import MediaPlayer

final class Player {
    static let shared = Player()
    let api = API()
    let audio = AVPlayer()
    lazy var room = RoomClient(player: self)
    var queue: [Song] = []
    var index = -1
    var mode = "list"
    var quality = "flac"
    var allowFallback = true
    var resolvedQuality = ""
    var wanted = false
    var loading = false
    var failure = ""
    var generation = 0
    var onState: ((Object) -> Void)?
    var onRoom: ((Object) -> Void)?
    var onRevoked: (() -> Void)?
    var queueRevision = 0
    var libraryRevision = 0
    var onChat: ((String, Object) -> Void)?
    var observers: [NSObjectProtocol] = []
    var statusObservation: NSKeyValueObservation?
    var clock: Any?
    var resolution: URLSessionDataTask?
    var prefetchTask: URLSessionDataTask?
    var artworkTask: URLSessionDataTask?
    var artwork: MPMediaItemArtwork?
    var currentURL: URL?
    var remoteTargets: [(MPRemoteCommand, Any)] = []
    var resumeTime = 0.0
    var notifyAt = 0.0
    var library: [Object] = []
    var lastWebQueueSignature = ""
    var interruptionWanted = false
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var position: Double { let n = audio.currentTime().seconds; return n.isFinite ? max(0, n) : 0 }
    var duration: Double { let n = audio.currentItem?.duration.seconds ?? 0; return n.isFinite ? max(0, n) : 0 }

    private init() {
        restoreQueue()
        audio.automaticallyWaitsToMinimizeStalling = false
        clock = audio.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in self?.tick() }
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self = self, n.object as? AVPlayerItem === self.audio.currentItem else { return }
            if self.room.active { self.room.ended() } else { self.move(automatic: true) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self else { return }
            let type = number(n.userInfo?[AVAudioSessionInterruptionTypeKey])
            if type == Double(AVAudioSession.InterruptionType.began.rawValue) { self.interruptionWanted = self.wanted; self.audio.pause(); self.publish() }
            else if self.interruptionWanted, (UInt(number(n.userInfo?[AVAudioSessionInterruptionOptionKey])) & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0 { self.play(user: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            if UInt(number(n.userInfo?[AVAudioSessionRouteChangeReasonKey])) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause(user: false) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] n in
            guard let self = self, n.object as? AVPlayerItem === self.audio.currentItem else { return }; self.fail(ClientError("当前音源播放中断"))
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.room.refresh(); self?.publish() })
        configureCommands()
    }
    func configure(_ credentials: Credentials?) {
        if api.credentials == credentials { return }
        prefetchTask?.cancel(); api.sourceCache.removeAll()
        if let old = api.credentials, let credentials = credentials, old.server == credentials.server, old.username == credentials.username {
            api.credentials = credentials; Vault.save(credentials); room.disconnect(clear: true); room.refresh(); return
        }
        pause(user: false); generation += 1; resolution?.cancel(); audio.replaceCurrentItem(with: nil); currentURL = nil
        room.disconnect(clear: true); queue = []; queueRevision += 1; index = -1; failure = ""; artwork = nil
        library = []; libraryRevision += 1; api.credentials = credentials; Vault.save(credentials); persistQueue(); persistLibrary(); room.refresh(); publish()
    }
    func configureCommands() {
        let c = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ body: @escaping () -> Void) {
            command.isEnabled = true
            let target = command.addTarget { _ in DispatchQueue.main.async(execute: body); return .success }
            remoteTargets.append((command, target))
        }
        add(c.playCommand) { [weak self] in self?.play() }
        add(c.pauseCommand) { [weak self] in self?.pause() }
        add(c.togglePlayPauseCommand) { [weak self] in guard let self = self else { return }; self.wanted ? self.pause() : self.play() }
        add(c.nextTrackCommand) { [weak self] in self?.move() }
        add(c.previousTrackCommand) { [weak self] in self?.move(previous: true) }
        add(c.stopCommand) { [weak self] in self?.pause() }
        c.skipForwardCommand.isEnabled = false; c.skipBackwardCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false; c.seekBackwardCommand.isEnabled = false
        let target = c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            DispatchQueue.main.async { self?.seek(event.positionTime) }; return .success
        }
        remoteTargets.append((c.changePlaybackPositionCommand, target))
    }
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try session.setActive(true)
    }
    func select(_ songs: [Song], index target: Int, paused: Bool = false, user: Bool = true, time: Double = 0) {
        guard songs.indices.contains(target) else { return }
        if room.active, songs[target].raw["deviceKey"] != nil || text(songs[target].raw["url"]).hasPrefix("file:") {
            failure = "设备文件仅能在本机播放，请先退出房间，或使用已分享的在线/网盘音源"; publish(); return
        }
        queue = songs; queueRevision += 1; index = target; wanted = !paused; resumeTime = max(0, time); loading = true; failure = ""; generation += 1
        let epoch = generation, song = songs[target]
        resolution?.cancel(); prefetchTask?.cancel(); artworkTask?.cancel(); artwork = nil
        audio.pause(); audio.replaceCurrentItem(with: nil); currentURL = nil
        if user { room.sendState(reason: "track") }
        persistQueue(); publish(); updateArtwork(song)
        resolution = api.resolve(song, quality: quality, allowFallback: allowFallback) { [weak self] result in
            guard let self = self, self.generation == epoch else { return }
            do {
                let (url, resolved) = try result.get()
                self.resolvedQuality = resolved; self.currentURL = url
                let item = AVPlayerItem(url: url)
                item.preferredForwardBufferDuration = 1
                self.statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.generation == epoch, self.audio.currentItem === item else { return }
                        if item.status == .failed { self.fail(item.error ?? ClientError("iOS 无法解码当前音源")) }
                        if item.status == .readyToPlay {
                            self.loading = false
                            if self.resumeTime > 0.1 { let time = self.resumeTime; self.resumeTime = 0; self.seek(time, user: false) }
                            if self.wanted { do { try self.activate(); self.audio.play() } catch { self.fail(error) } }
                            self.room.mediaReady(); self.prefetchNext(); self.publish()
                        }
                    }
                }
                self.audio.replaceCurrentItem(with: item)
                if self.wanted { try self.activate(); self.audio.play() }
                self.publish()
            } catch { self.fail(error) }
        }
    }
    func prefetchNext() {
        guard mode != "random", let next = QueuePolicy.next(count: queue.count, index: index, mode: mode, automatic: true), next != index else { return }
        let song = queue[next]
        guard song.raw["deviceKey"] == nil, song.raw["openlist"] == nil, !bool(song.raw["isLocal"]) else { return }
        // Resolve one future address only. AVPlayer opens audio when selected.
        prefetchTask = api.resolve(song, quality: quality, allowFallback: allowFallback) { _ in }
    }
    func play(user: Bool = true) {
        guard current != nil else { return }
        wanted = true; failure = ""
        if audio.currentItem == nil { select(queue, index: index, user: user, time: resumeTime); return }
        do { try activate(); audio.play(); if user { room.sendState(reason: "play") }; publish() } catch { fail(error) }
    }
    func pause(user: Bool = true) {
        wanted = false; audio.pause(); if user { room.sendState(reason: "pause") }; persistQueue(); publish()
    }
    func seek(_ time: Double, user: Bool = true) {
        let target = max(0, duration > 0 ? min(time, max(0, duration - 0.05)) : time)
        audio.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if user { room.sendState(reason: "seek", position: target) }; publish()
    }
    func move(previous: Bool = false, automatic: Bool = false) {
        if room.active, automatic { room.ended(); return }
        guard let target = QueuePolicy.next(count: queue.count, index: index, mode: mode, previous: previous, automatic: automatic) else { pause(); return }
        select(queue, index: target)
    }
    func fail(_ error: Error) {
        loading = false; wanted = false; audio.pause(); failure = error.localizedDescription; publish()
    }
    func tick() {
        publish(includeQueue: false)
        let now = Date().timeIntervalSince1970
        if now - notifyAt >= 5 { notifyAt = now; persistQueue(); room.progress() }
    }
    func snapshot(includeQueue: Bool = true) -> Object {
        var value: Object = ["queueRevision": queueRevision, "index": index, "mode": mode, "song": current?.raw ?? [:], "position": position, "duration": duration, "paused": !wanted, "playing": audio.rate > 0, "loading": loading, "quality": resolvedQuality, "error": failure, "volume": audio.volume, "muted": audio.isMuted]
        if includeQueue { value["queue"] = queue.map(\.raw) }; return value
    }
    func publish(includeQueue: Bool = true) {
        updateNowPlaying(); onState?(snapshot(includeQueue: includeQueue)); NotificationCenter.default.post(name: .lxPlayback, object: self)
    }
    func updateNowPlaying() {
        let c = MPRemoteCommandCenter.shared()
        c.nextTrackCommand.isEnabled = queue.count > 1; c.previousTrackCommand.isEnabled = queue.count > 1
        c.changePlaybackPositionCommand.isEnabled = duration > 0
        guard let song = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: Object = [MPMediaItemPropertyTitle: song.name, MPMediaItemPropertyArtist: song.artist, MPMediaItemPropertyAlbumTitle: text(song.raw["albumName"]), MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: audio.rate, MPNowPlayingInfoPropertyDefaultPlaybackRate: 1, MPNowPlayingInfoPropertyPlaybackQueueIndex: max(0, index), MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork = artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    func updateArtwork(_ song: Song) {
        guard let base = api.base, let url = URL(string: text(song.raw["img"]), relativeTo: base), ["http", "https"].contains(url.scheme ?? "") else { return }
        let epoch = generation
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, data.count < 8_000_000, let image = UIImage(data: data) else { return }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512))
            let thumbnail = renderer.image { _ in image.draw(in: CGRect(x: 0, y: 0, width: 512, height: 512)) }
            DispatchQueue.main.async { guard let self = self, self.generation == epoch else { return }; self.artwork = MPMediaItemArtwork(boundsSize: thumbnail.size) { _ in thumbnail }; self.updateNowPlaying() }
        }
        artworkTask?.resume()
    }
    func persistQueue() {
        guard let credentials = api.credentials else { UserDefaults.standard.removeObject(forKey: "lx.queue"); return }
        let object: Object = ["server": credentials.server, "username": credentials.username, "queue": queue.map(\.raw), "index": index, "mode": mode, "position": position, "quality": quality]
        if let data = try? JSONSerialization.data(withJSONObject: object) { UserDefaults.standard.set(data, forKey: "lx.queue") }
    }
    func restoreQueue() {
        guard let data = UserDefaults.standard.data(forKey: "lx.queue"), let object = (try? JSONSerialization.jsonObject(with: data)) as? Object,
              text(object["server"]) == api.credentials?.server, text(object["username"]) == api.credentials?.username else { return }
        queue = (object["queue"] as? [Object] ?? []).map { Song(raw: $0) }; index = Int(number(object["index"], -1)); mode = text(object["mode"]); quality = text(object["quality"]); resumeTime = number(object["position"])
        if let stored = UserDefaults.standard.data(forKey: "lx.library"), let lists = (try? JSONSerialization.jsonObject(with: stored)) as? [Object] { library = lists }
    }
    func persistLibrary() { if let data = try? JSONSerialization.data(withJSONObject: library) { UserDefaults.standard.set(data, forKey: "lx.library") } }
    func refreshLibrary(_ completion: (() -> Void)? = nil) {
        api.request("/api/user/list") { [weak self] result in
            guard let self = self else { return }
            if case .success(let data) = result {
                self.library = [["id": "love", "name": "我的收藏", "list": data["loveList"] as? [Object] ?? []], ["id": "default", "name": "默认列表", "list": data["defaultList"] as? [Object] ?? []]] + (data["userList"] as? [Object] ?? [])
                self.libraryRevision += 1; self.persistLibrary(); NotificationCenter.default.post(name: .lxLibrary, object: self)
            }
            completion?()
        }
    }
}
extension Notification.Name { static let lxPlayback = Notification.Name("LXNativePlayback"); static let lxRoom = Notification.Name("LXNativeRoom"); static let lxLibrary = Notification.Name("LXNativeLibrary") }
