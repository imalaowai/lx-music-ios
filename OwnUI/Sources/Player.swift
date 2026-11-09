import UIKit
import AVFoundation
import MediaPlayer

final class Player {
    static let shared = Player()
    let api = API()
    let audio = ReferenceAudio()
    lazy var room = RoomClient(player: self)
    var queue: [Song] = []
    var recent: [Song] = []
    private var recentRecordedGeneration = -1
    private static let recentLimit = 50
    var index = -1
    var mode = "list"
    var quality = "flac"
    var allowFallback = true
    var resolvedQuality = ""
    var resolvedQualityReported = false
    var wanted = false
    var loading = false
    var failure = ""
    var generation = 0
    var onState: ((Object) -> Void)?
    var onRoom: ((Object) -> Void)?
    var onRevoked: (() -> Void)?
    var queueRevision = 0
    private var emittedQueueRevision = -1
    private var storedQueueRevision = -1
    private var storedRecentRevision = -1
    private var queueStorageID = ""
    private(set) var recentRevision = 0
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
    var artworkLookup: Cancellable?
    var artworkIdentity = ""
    var artworkLookupAttempted = false
    var resolvedArtwork = ""
    private var rejectedArtwork = Set<String>()
    private var publishedArtwork = ""
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
    var playbackAdvancing: Bool {
        wanted && !loading && !seeking && !interrupted && !endGuard.handled && audio.timeControlStatus == .playing
    }
    var position: Double { let n = audio.currentTime().seconds; return n.isFinite ? max(0, n) : 0 }
    var duration: Double { let n = audio.currentItem?.duration.seconds ?? 0; return n.isFinite ? max(0, n) : 0 }

    var lastOutputLossAt = 0.0
    private init() {
        api.onSessionExpired = { [weak self] in self?.revokeSession() }
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
            observers.append(NotificationCenter.default.addObserver(forName:Notification.Name(name),object:nil,queue:.main) { [weak self] note in
                guard let self = self else { return }
                let value = note.userInfo as? Object ?? [:]
                let command = text(value["command"])
                if name == "LXRemoteCommand", ["play", "next", "previous"].contains(command) || (command == "toggle" && !self.wanted) {
                    self.performCarPlayAction { [weak self] in self?.remote(value) }
                } else {
                    self.remote(value)
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName:Notification.Name("LXOwnArtworkMissing"),object:nil,queue:.main) { [weak self] note in
            guard let self = self, let song = self.current,
                  text(note.userInfo?["songId"]) == song.playbackIdentity,
                  number(note.userInfo?["generation"], -1) == Double(self.generation) else { return }
            let address = text(note.userInfo?["artwork"])
            guard address == self.publishedArtwork, self.rejectedArtwork.insert(address).inserted else { return }
            self.nowPlayingSignature = ""
            self.publish()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.room.recoverConnection("phone-active")
            self?.refreshNowPlaying()
            self?.publish()
        })
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
        routeGate.suspend(); room.cancelCarPlayAction(); UserDefaults.standard.set(true,forKey:"lx.routeHold"); generation += 1
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
    func performCarPlayAction(_ action: @escaping () -> Void) {
        let routeEpoch = routeGate.epoch
        room.afterInitialBinding { [weak self] in
            guard self?.routeGate.epoch == routeEpoch else { return }
            action()
        }
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
        prefetchTask?.cancel()
        if let old = api.credentials, let credentials = credentials, old.server == credentials.server, old.username == credentials.username {
            api.credentials = credentials; Vault.save(credentials); room.disconnect(clear: true)
            if loading, current != nil { select(queue, index:index, paused:!wanted, user:false, time:resumeTime, reuseQueue:true) }
            else { failure = ""; publish() }
            room.refresh(); return
        }
        finishTransition(); pause(user: false); generation += 1; resolution?.cancel(); audio.replaceCurrentItem(with: nil); currentURL = nil
        loading = false; seeking = false; endGuard.reset(generation, now:ProcessInfo.processInfo.systemUptime)
        room.disconnect(clear: true); queue = []; recent = []; recentRevision += 1; queueRevision += 1; index = -1; resumeTime = 0; failure = ""
        library = []; libraryRevision += 1; api.credentials = credentials; Vault.save(credentials); persistQueue(); persistLibrary(); room.refresh(); publish()
    }
    func revokeSession() {
        guard api.credentials != nil else { return }
        UserDefaults.standard.set(true, forKey:Vault.webSessionMigratedKey)
        configure(nil)
        failure = "账号登录已失效，请重新登录"
        publish(); onRevoked?()
    }
    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        try session.setActive(true)
    }
    func select(_ songs: [Song], index target: Int, paused: Bool = false, user: Bool = true, time: Double = 0, reuseQueue: Bool = false) {
        guard songs.indices.contains(target) else { return }
        if room.active, text(songs[target].raw["source"]) == "local" || songs[target].raw["deviceKey"] != nil || text(songs[target].raw["url"]).hasPrefix("file:") {
            failure = "设备文件仅能在本机播放，请先退出房间，或使用已分享的在线/网盘音源"; publish(); return
        }
        if user && !paused { resumeAfterUserAction() }
        if !reuseQueue { queue = songs; queueRevision += 1 }
        index = target; wanted = !paused && !routeGate.held; resumeTime = max(0, time); loading = !routeGate.held; failure = ""; resolvedQuality = ""; resolvedQualityReported = false; generation += 1
        resetArtwork()
        timelineRevision += 1; seeking = false
        endGuard.reset(generation, now: ProcessInfo.processInfo.systemUptime)
        finishTransition()
        if routeGate.held {
            resolution?.cancel(); prefetchTask?.cancel()
            audio.pause(); audio.replaceCurrentItem(with:nil,preservingNowPlaying:true); currentURL = nil
            persistQueue(); publish(); return
        }
        transitionTask = UIApplication.shared.beginBackgroundTask(withName: "LX Track Transition") { [weak self] in
            guard let self = self else { return }; self.generation += 1; self.resolution?.cancel(); self.fail(ClientError("后台播放链接请求超时，请恢复网络后播放"))
        }
        let epoch = generation, song = songs[target]
        let requestedQuality = QualityPolicy.best(for: song.raw, preference: quality, allowFallback: allowFallback)
        RuntimeTrace.record("audio.quality-request", ["source": text(song.raw["source"]), "preference": quality, "requested": requestedQuality, "fallback": allowFallback])
        resolution?.cancel(); prefetchTask?.cancel()
        audio.pause(); audio.replaceCurrentItem(with: nil,preservingNowPlaying:true); currentURL = nil
        if user { room.sendState(reason: "track") }
        persistQueue(); publish()
        resolution = api.resolve(song, quality: requestedQuality, allowFallback: allowFallback) { [weak self] result in
            guard let self = self, self.generation == epoch else { return }
            do {
                let media = try result.get()
                self.resolvedQuality = media.playbackQuality; self.resolvedQualityReported = media.qualityReported; self.currentURL = media.url
                RuntimeTrace.record("audio.quality-resolved", ["source": text(song.raw["source"]), "requested": requestedQuality, "reported": media.playbackQuality, "qualityReported": media.qualityReported])
                if self.wanted { try self.activate() }
                let position=self.resumeTime;self.resumeTime=0
                self.audio.load(media.url,song:song,quality:media.playbackQuality,position:position,paused:!self.wanted) { [weak self] result in
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
        guard song.raw["openlist"] == nil, song.raw["deviceKey"] != nil || !bool(song.raw["isLocal"]) else { return }
        // Resolve one future address only. The reference core opens it when selected.
        let requestedQuality = QualityPolicy.best(for: song.raw, preference: quality, allowFallback: allowFallback)
        prefetchTask = api.resolve(song, quality: requestedQuality, allowFallback: allowFallback) { _ in }
    }
    func play(user: Bool = true) {
        guard current != nil else { return }
        guard routeGate.permitsPlayback(user:user) else { return }
        let wasHeld = routeGate.held
        if user { resumeAfterUserAction() }
        if user && wasHeld && room.active {
            let position = room.target(room.state), hostPaused = bool(room.state["paused"],true)
            if audio.currentItem == nil || audio.hasFailed { select(queue,index:index,user:false,time:position,reuseQueue:true) }
            else {
                wanted=true
                do { try activate();seek(position,user:false);audio.play();publish() } catch { fail(error) }
            }
            if hostPaused && wanted { room.sendState(reason:"play",position:position) }
            return
        }
        if endGuard.handled, !room.active { select(queue, index: index, user: user, reuseQueue: true); return }
        wanted = true; failure = ""
        if audio.currentItem == nil || audio.hasFailed { select(queue, index: index, user: user, time: resumeTime, reuseQueue: true); return }
        do { try activate(); audio.play(); if user { room.sendState(reason: "play") }; publish() } catch { fail(error) }
    }
    func pause(user: Bool = true) {
        if user { room.cancelCarPlayAction() }
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
        select(queue, index: target, reuseQueue: true)
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
        let sample = audio.positionSample()
        var value: Object = ["sampledAt": Date().timeIntervalSince1970 * 1000, "positionSampledAt": sample.timestamp * 1000, "queueRevision": queueRevision, "index": index, "mode": mode, "song": current?.raw ?? [:], "position": sample.position, "duration": duration, "paused": !wanted, "playing": playbackAdvancing, "playbackRate": playbackAdvancing ? audio.rate : 0, "routeHold":routeGate.held, "timelineRevision": timelineRevision, "seeking": seeking, "ended": endGuard.handled, "loading": loading, "quality": resolvedQuality, "qualityReported": resolvedQualityReported, "error": failure, "volume": audio.volume, "muted": audio.isMuted]
        if includeQueue { value["queue"] = queue.map(\.raw) }; return value
    }
    func publish(includeQueue: Bool = true) {
        let recorded = recordRecentPlayback()
        let changedQueue = includeQueue && emittedQueueRevision != queueRevision
        if changedQueue, onState != nil { emittedQueueRevision = queueRevision }
        updateNowPlaying(); onState?(snapshot(includeQueue: changedQueue))
        let signature = "\(generation)|\(wanted)|\(loading)|\(failure)|\(queueRevision)|\(audio.timeControlStatus.rawValue)"
        if recorded || signature != lastWebQueueSignature { lastWebQueueSignature = signature; NotificationCenter.default.post(name: .lxPlayback, object: self) }
    }
    private func recordRecentPlayback() -> Bool {
        guard !loading, wanted, audio.timeControlStatus == .playing,
              recentRecordedGeneration != generation, let song = current else { return false }
        recentRecordedGeneration = generation; recentRevision += 1
        recent.removeAll { $0.playbackIdentity == song.playbackIdentity }
        recent.insert(song, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        persistQueue()
        return true
    }
    func resetArtwork() {
        artworkLookup?.cancel();artworkLookup=nil;artworkIdentity="";artworkLookupAttempted=false;resolvedArtwork=""
        rejectedArtwork.removeAll()
        publishedArtwork = ""
    }
    func resolveArtwork(_ song: Song) {
        guard !artworkLookupAttempted,(wanted || currentURL != nil) else { return }
        artworkLookupAttempted=true
        let identity=artworkIdentity, epoch=generation
        artworkLookup=api.cover(song) { [weak self] result in
            guard let self=self,self.artworkIdentity==identity,self.generation==epoch else { return }
            self.artworkLookup=nil
            if case .success(let address)=result {
                self.resolvedArtwork=address;self.nowPlayingSignature="";self.publish()
            }
        }
    }
    func nowPlayingArtwork(_ song: Song) -> String {
        let identity=song.playbackIdentity
        if artworkIdentity != identity { resetArtwork();artworkIdentity=identity }
        if let file = MusicLibrary.shared.coverURL(text(song.raw["offlineId"])),
           !rejectedArtwork.contains(file.absoluteString) { return file.absoluteString }
        if let embedded = ArtworkAddress.candidates(song, base: api.base).first(where: { !rejectedArtwork.contains($0) }) { return embedded }
        if !resolvedArtwork.isEmpty, !rejectedArtwork.contains(resolvedArtwork) { return resolvedArtwork }
        resolveArtwork(song)
        return ""
    }
    func updateNowPlaying() {
        guard let song=current else { resetArtwork();audio.clearMetadata();return }
        let cover=nowPlayingArtwork(song)
        let signature = "\(generation)|\(wanted)|\(loading)|\(interrupted)|\(audio.timeControlStatus.rawValue)|\(audio.rate)|\(timelineRevision)|\(playbackAdvancing)|\(Int(duration))|\(queueRevision)|\(song.key)|\(cover)"
        let now = ProcessInfo.processInfo.systemUptime
        guard signature != nowPlayingSignature || now - nowPlayingAt > 15 else { return }
        nowPlayingSignature = signature; nowPlayingAt = now; publishedArtwork = cover
        let knownDuration = duration > 0 ? duration : SongInterval.seconds(song.raw["interval"])
        audio.metadata(["songId":song.playbackIdentity,"generation":generation,"title":song.name,"artist":song.artist,"album":text(song.raw["albumName"]),"artwork":cover,"artworkResolved":!resolvedArtwork.isEmpty,"duration":knownDuration,"elapsedTime":position,"wanted":wanted,"interrupted":interrupted,"loading":loading || audio.timeControlStatus == .waitingToPlayAtSpecifiedRate,"playbackRate":playbackAdvancing ? audio.rate : 0])
    }
    func refreshNowPlaying() {
        nowPlayingSignature = ""
        updateNowPlaying()
    }
    func persistQueue() {
        let defaults = UserDefaults.standard
        let identity = ["server":api.credentials?.server ?? "", "username":api.credentials?.username ?? ""]
        let progress: Object = ["index":index, "mode":mode, "quality":quality, "position":currentURL == nil ? resumeTime : position]
        if storedQueueRevision != queueRevision {
            let id = UUID().uuidString
            var object = progress
            object["snapshotId"] = id; object["queue"] = queue.map(\.raw); object["recent"] = recent.map(\.raw)
            for (key, value) in identity { object[key] = value }
            guard let data = try? JSONSerialization.data(withJSONObject:object) else { return }
            defaults.set(data, forKey:"lx.queue")
            storedQueueRevision = queueRevision; queueStorageID = id
        }
        if storedRecentRevision != recentRevision {
            var object: Object = identity
            object["recent"] = recent.map(\.raw)
            if let data = try? JSONSerialization.data(withJSONObject:object) {
                defaults.set(data, forKey:"lx.recentPlayback"); storedRecentRevision = recentRevision
            }
        }
        var checkpoint = progress
        checkpoint["snapshotId"] = queueStorageID
        defaults.set(checkpoint, forKey:"lx.queueProgress")
    }
    func restoreQueue() {
        let defaults = UserDefaults.standard
        let identityMatches: (Object) -> Bool = { object in
            text(object["server"]) == (self.api.credentials?.server ?? "") && text(object["username"]) == (self.api.credentials?.username ?? "")
        }
        guard let data = defaults.data(forKey:"lx.queue"), let object = (try? JSONSerialization.jsonObject(with:data)) as? Object,
              identityMatches(object) else { return }
        queue = (object["queue"] as? [Object] ?? []).map { Song(raw:$0) }
        queueStorageID = text(object["snapshotId"])
        let saved = defaults.dictionary(forKey:"lx.queueProgress")
        let progress = !queueStorageID.isEmpty && text(saved?["snapshotId"]) == queueStorageID ? (saved ?? object) : object
        let target = Int(number(progress["index"], -1))
        index = queue.indices.contains(target) ? target : -1
        mode = ["list","single","order","random"].contains(text(progress["mode"])) ? text(progress["mode"]) : "list"
        if !text(progress["quality"]).isEmpty { quality = text(progress["quality"]) }
        resumeTime = number(progress["position"])
        let persistedRecent = defaults.data(forKey:"lx.recentPlayback").flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? Object }
        let recentRows = persistedRecent.flatMap { identityMatches($0) ? $0["recent"] as? [Object] : nil }
            ?? object["recent"] as? [Object] ?? (current.map { [$0.raw] } ?? [])
        recent = recentRows.prefix(Self.recentLimit).map { Song(raw:$0) }
        if !queueStorageID.isEmpty { storedQueueRevision = queueRevision }
        if let stored = defaults.data(forKey:"lx.library"), let lists = (try? JSONSerialization.jsonObject(with:stored)) as? [Object] { library = lists }
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
