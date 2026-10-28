import UIKit
import AVFoundation
import MediaPlayer

final class Player {
    static let shared = Player()
    let api = API()
    let audio = ReferenceAudio()
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
    var playbackObservation: NSKeyValueObservation?
    var timelineRevision = 0
    var seeking = false
    var clock: Any?
    var watchdog: Timer?
    var endGuard = PlaybackEndGuard()
    var nowPlayingSignature = ""
    var nowPlayingAt = 0.0
    var resolution: Cancellable?
    var transitionTask: UIBackgroundTaskIdentifier = .invalid
    var prefetchTask: Cancellable?
    var artworkTask: URLSessionDataTask?
    var artwork: MPMediaItemArtwork?
    var currentURL: URL?
    var remoteTargets: [(MPRemoteCommand, Any)] = []
    var resumeTime = 0.0
    var notifyAt = 0.0
    var library: [Object] = []
    var lastWebQueueSignature = ""
    var interruptionWanted = false
    var interrupted = false
    var routeGate = PlaybackRouteGate()
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    var position: Double { let n = audio.currentTime().seconds; return n.isFinite ? max(0, n) : 0 }
    var duration: Double { let n = audio.currentItem?.duration.seconds ?? 0; return n.isFinite ? max(0, n) : 0 }

    var lastOutputLossAt = 0.0
    private init() {
        restoreQueue()
        if UserDefaults.standard.bool(forKey:"lx.routeHold") {
            routeGate.suspend()
            NotificationCenter.default.post(name:Notification.Name("LXOwnAudioRouteHold"),object:nil,userInfo:["held":true])
        }
        audio.didChange = { [weak self] in self?.tick() }
        audio.didEnd = { [weak self] in self?.finishNaturally() }
        audio.didFail = { [weak self] error in self?.fail(error) }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.endGuard.stalledAtEnd(position:self.position,duration:self.duration,wanted:self.wanted,loading:self.loading,seeking:self.seeking,playing:self.audio.timeControlStatus == .playing,now:ProcessInfo.processInfo.systemUptime) { self.finishNaturally() }
        }
        for name in ["LXRemoteCommand", "LXOwnRemoteCommand"] {
            observers.append(NotificationCenter.default.addObserver(forName:Notification.Name(name),object:nil,queue:.main) { [weak self] note in self?.remote(note.userInfo as? Object ?? [:]) })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.room.recoverConnection("phone-active"); self?.publish() })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,object:nil,queue:.main) { [weak self] note in
            guard let self=self else { return }
            if number(note.userInfo?[AVAudioSessionInterruptionTypeKey]) == Double(AVAudioSession.InterruptionType.began.rawValue) {
                self.interrupted=true;self.interruptionWanted=self.wanted;self.audio.pause();self.publish()
            } else {
                self.interrupted=false
                let resume=self.interruptionWanted && self.wanted && !self.routeGate.held && (UInt(number(note.userInfo?[AVAudioSessionInterruptionOptionKey])) & AVAudioSession.InterruptionOptions.shouldResume.rawValue) != 0
                self.interruptionWanted=false
                if resume { self.play(user:false) } else { self.pause(user:false) }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,object:nil,queue:.main) { [weak self] note in
            let reason=UInt(number(note.userInfo?[AVAudioSessionRouteChangeReasonKey]))
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.suspendForOutputLoss() }
            self?.room.recoverConnection("audio-route")
            if reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                NotificationCenter.default.post(name:Notification.Name("LXOwnCarPlayReconcile"),object:nil)
            }
        })
    }
    func suspendForOutputLoss() {
        guard !routeGate.held else { return }
        lastOutputLossAt=ProcessInfo.processInfo.systemUptime
        routeGate.suspend(); UserDefaults.standard.set(true,forKey:"lx.routeHold"); generation += 1
        endGuard.reset(generation, now:ProcessInfo.processInfo.systemUptime)
        resolution?.cancel(); prefetchTask?.cancel(); finishTransition(); loading = false
        // The native decoder guard receives this synchronously, independently
        // of the RN JavaScript queue, which may be asleep in the background.
        NotificationCenter.default.post(name: Notification.Name("LXOwnAudioRouteHold"), object: nil, userInfo: ["held":true])
        RuntimeTrace.record("audio.output-lost",["generation":generation,"routeHold":true])
        pause(user:false)
    }
    func resumeAfterUserAction() {
        routeGate.resumeByUser(); UserDefaults.standard.set(false,forKey:"lx.routeHold")
        NotificationCenter.default.post(name: Notification.Name("LXOwnAudioRouteHold"), object: nil, userInfo: ["held":false])
    }
    func remote(_ value:Object) {
        let command=text(value["command"])
        let eventAt=number(value["eventAt"])
        if eventAt>0 && eventAt<lastOutputLossAt {
            RuntimeTrace.record("audio.stale-remote-ignored",["command":command]);return
        }
        // Track skipping has one native entry point. Do not debounce identical commands by
        // wall-clock spacing: a real double tap must advance twice, not disappear within 200 ms.
        switch command { case "play":play();case "pause", "stop":pause();case "toggle":wanted ? pause() : play();case "next":move();case "previous":move(previous:true);case "seek":seek(number(value["position"]));default:break }
    }
    func configure(_ credentials: Credentials?) {
        if api.credentials == credentials { return }
        prefetchTask?.cancel(); api.sourceCache.removeAll()
        if let old = api.credentials, let credentials = credentials, old.server == credentials.server, old.username == credentials.username {
            api.credentials = credentials; Vault.save(credentials); room.disconnect(clear: true); room.refresh(); return
        }
        finishTransition(); pause(user: false); generation += 1; resolution?.cancel(); audio.replaceCurrentItem(with: nil); currentURL = nil
        room.disconnect(clear: true); queue = []; queueRevision += 1; index = -1; failure = ""; artwork = nil
        library = []; libraryRevision += 1; api.credentials = credentials; Vault.save(credentials); persistQueue(); persistLibrary(); room.refresh(); publish()
    }
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try session.setActive(true)
    }
    func select(_ songs: [Song], index target: Int, paused: Bool = false, user: Bool = true, time: Double = 0) {
        guard songs.indices.contains(target) else { return }
        if room.active, text(songs[target].raw["source"]) == "local" || songs[target].raw["deviceKey"] != nil || text(songs[target].raw["url"]).hasPrefix("file:") {
            failure = "设备文件仅能在本机播放，请先退出房间，或使用已分享的在线/网盘音源"; publish(); return
        }
        if user && !paused { resumeAfterUserAction() }
        queue = songs; queueRevision += 1; index = target; wanted = !paused && !routeGate.held; resumeTime = max(0, time); loading = !routeGate.held; failure = ""; generation += 1
        timelineRevision += 1; seeking = false
        endGuard.reset(generation, now: ProcessInfo.processInfo.systemUptime)
        finishTransition()
        if routeGate.held {
            resolution?.cancel(); prefetchTask?.cancel(); artworkTask?.cancel()
            audio.pause(); audio.replaceCurrentItem(with:nil,preservingNowPlaying:true); currentURL = nil
            persistQueue(); publish(); return
        }
        transitionTask = UIApplication.shared.beginBackgroundTask(withName: "LX Track Transition") { [weak self] in
            guard let self = self else { return }; self.generation += 1; self.resolution?.cancel(); self.fail(ClientError("后台播放链接请求超时，请恢复网络后播放"))
        }
        let epoch = generation, song = songs[target]
        resolution?.cancel(); prefetchTask?.cancel(); artworkTask?.cancel(); artwork = nil
        audio.pause(); audio.replaceCurrentItem(with: nil,preservingNowPlaying:true); currentURL = nil
        if user { room.sendState(reason: "track") }
        persistQueue(); publish()
        resolution = api.resolve(song, quality: quality, allowFallback: allowFallback) { [weak self] result in
            guard let self = self, self.generation == epoch else { return }
            do {
                let (url, resolved) = try result.get()
                self.resolvedQuality = resolved; self.currentURL = url
                if self.wanted { try self.activate() }
                let position=self.resumeTime;self.resumeTime=0
                self.audio.load(url,song:song,quality:resolved,position:position,paused:!self.wanted) { [weak self] result in
                    guard let self=self,self.generation==epoch else { return }
                    switch result {
                    case .success: self.loading=false;self.finishTransition();self.room.mediaReady();self.prefetchNext();self.publish()
                    case .failure(let error):self.fail(error)
                    }
                }
                self.publish()
            } catch { self.fail(error) }
        }
    }
    func finishTransition() {
        if transitionTask != .invalid { UIApplication.shared.endBackgroundTask(transitionTask); transitionTask = .invalid }
    }
    func prefetchNext() {
        guard mode != "random", let next = QueuePolicy.next(count: queue.count, index: index, mode: mode, automatic: true), next != index else { return }
        let song = queue[next]
        guard song.raw["deviceKey"] == nil, song.raw["openlist"] == nil, !bool(song.raw["isLocal"]) else { return }
        // Resolve one future address only. The reference core opens it when selected.
        prefetchTask = api.resolve(song, quality: quality, allowFallback: allowFallback) { _ in }
    }
    func play(user: Bool = true) {
        guard current != nil else { return }
        guard routeGate.permitsPlayback(user:user) else { return }
        let wasHeld = routeGate.held
        if user { resumeAfterUserAction() }
        if user && wasHeld && room.active {
            let position = room.target(room.state), hostPaused = bool(room.state["paused"],true)
            if audio.currentItem == nil || audio.hasFailed { select(queue,index:index,user:false,time:position) }
            else {
                wanted=true
                do { try activate();seek(position,user:false);audio.play();publish() } catch { fail(error) }
            }
            if hostPaused && wanted { room.sendState(reason:"play",position:position) }
            return
        }
        if endGuard.handled, !room.active { select(queue, index: index, user: user); return }
        wanted = true; failure = ""
        if audio.currentItem == nil || audio.hasFailed { select(queue, index: index, user: user, time: resumeTime); return }
        do { try activate(); audio.play(); if user { room.sendState(reason: "play") }; publish() } catch { fail(error) }
    }
    func pause(user: Bool = true) {
        interruptionWanted = false; wanted = false; audio.pause(); if user { room.sendState(reason: "pause") }; persistQueue(); publish()
    }
    func seek(_ time: Double, user: Bool = true) {
        let target = max(0, duration > 0 ? min(time, max(0, duration - 0.05)) : time)
        if audio.currentItem == nil { resumeTime=target; if user { room.sendState(reason:"seek",position:target) };publish();return }
        timelineRevision += 1; seeking = true
        endGuard.reset(generation, now: ProcessInfo.processInfo.systemUptime)
        let revision = timelineRevision, epoch = generation
        audio.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.timelineRevision == revision, self.generation == epoch else { return }
                self.seeking = false; self.publish(includeQueue: false)
            }
        }
        if user { room.sendState(reason: "seek", position: target) }; publish()
    }
    func move(previous: Bool = false, automatic: Bool = false) {
        if room.active, automatic { room.ended(); return }
        guard let target = QueuePolicy.next(count: queue.count, index: index, mode: mode, previous: previous, automatic: automatic) else { pause(); return }
        select(queue, index: target)
    }
    func finishNaturally() {
        guard wanted, endGuard.claim(generation) else { return }
        audio.pause()
        if room.active {
            finishTransition()
            let epoch = generation
            transitionTask = UIApplication.shared.beginBackgroundTask(withName: "LX Room End Transition") { [weak self] in
                guard let self = self, self.generation == epoch else { return }; self.fail(ClientError("房间下一首响应超时，请恢复连接"))
            }
            room.ended(); publish(includeQueue: false)
        } else { move(automatic: true) }
    }
    func fail(_ error: Error) {
        guard wanted || loading || failure.isEmpty else { return }
        generation += 1; resolution?.cancel(); prefetchTask?.cancel()
        audio.failedGeneration=audio.generation;audio.pending.removeAll()
        RuntimeTrace.record("player.failure",["generation":generation,"error":error.localizedDescription])
        finishTransition(); loading = false; wanted = false; audio.pause(); failure = error.localizedDescription; publish()
    }
    func tick() {
        publish(includeQueue: false)
        let now = Date().timeIntervalSince1970
        if now - notifyAt >= 5 { notifyAt = now; persistQueue(); room.progress() }
    }
    func snapshot(includeQueue: Bool = true) -> Object {
        var value: Object = ["sampledAt": Date().timeIntervalSince1970 * 1000, "queueRevision": queueRevision, "index": index, "mode": mode, "song": current?.raw ?? [:], "position": position, "duration": duration, "paused": !wanted, "playing": wanted && audio.timeControlStatus == .playing && !seeking && !endGuard.handled, "playbackRate": wanted ? audio.rate : 0, "routeHold":routeGate.held, "timelineRevision": timelineRevision, "seeking": seeking, "ended": endGuard.handled, "loading": loading, "quality": resolvedQuality, "error": failure, "volume": audio.volume, "muted": audio.isMuted]
        if includeQueue { value["queue"] = queue.map(\.raw) }; return value
    }
    func publish(includeQueue: Bool = true) {
        updateNowPlaying(); onState?(snapshot(includeQueue: includeQueue))
        let signature = "\(generation)|\(wanted)|\(loading)|\(failure)|\(queueRevision)|\(audio.timeControlStatus.rawValue)"
        if signature != lastWebQueueSignature { lastWebQueueSignature = signature; NotificationCenter.default.post(name: .lxPlayback, object: self) }
    }
    func updateNowPlaying() {
        let signature = "\(generation)|\(wanted)|\(loading)|\(interrupted)|\(audio.timeControlStatus.rawValue)|\(audio.rate)|\(timelineRevision)|\(Int(duration))|\(queueRevision)|\(current?.key ?? "")"
        let now = ProcessInfo.processInfo.systemUptime
        guard signature != nowPlayingSignature || now - nowPlayingAt > 15 else { return }
        nowPlayingSignature = signature; nowPlayingAt = now
        guard let song=current else { audio.clearMetadata(); return }
        var cover=text(song.raw["img"])
        if let id=song.raw["offlineId"] as? String,let folder=try? MusicLibrary.shared.folder(id) {
            let file=folder.appendingPathComponent("封面.jpg")
            // The reference module's local artwork API accepts a path, not file://.
            if FileManager.default.fileExists(atPath:file.path) { cover=file.path }
        }
        let knownDuration = duration > 0 ? duration : number(song.raw["interval"])
        audio.metadata(["songId":text(song.raw["source"])+"|"+song.key,"generation":generation,"title":song.name,"artist":song.artist,"album":text(song.raw["albumName"]),"artwork":cover,"duration":knownDuration,"elapsedTime":position,"wanted":wanted,"interrupted":interrupted,"loading":loading || audio.timeControlStatus == .waitingToPlayAtSpecifiedRate,"playbackRate":wanted ? audio.rate : 0])
    }
    func persistQueue() {
        let object: Object = ["server": api.credentials?.server ?? "", "username": api.credentials?.username ?? "", "queue": queue.map(\.raw), "index": index, "mode": mode, "position": position, "quality": quality]
        if let data = try? JSONSerialization.data(withJSONObject: object) { UserDefaults.standard.set(data, forKey: "lx.queue") }
    }
    func restoreQueue() {
        guard let data = UserDefaults.standard.data(forKey: "lx.queue"), let object = (try? JSONSerialization.jsonObject(with: data)) as? Object,
              text(object["server"]) == (api.credentials?.server ?? ""), text(object["username"]) == (api.credentials?.username ?? "") else { return }
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
