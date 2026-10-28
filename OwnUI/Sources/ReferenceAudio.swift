import Foundation
import AVFoundation

// Online audio uses the reference TrackPlayer / streaming FLAC modules.
// On-device files use AVAudioPlayer directly, without web URLs or a JS load.
final class ReferenceAudio: NSObject, AVAudioPlayerDelegate {
    var localAudio: AVAudioPlayer?
    final class Item { var duration = CMTime.zero }
    var currentItem: Item?
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var rate: Float = 0
    var volume: Float = 1 { didSet { if let local = localAudio { local.volume = isMuted ? 0 : volume } else { send("volume", ["volume": isMuted ? 0 : volume]) } } }
    var isMuted = false { didSet { if let local = localAudio { local.volume = isMuted ? 0 : volume } else { send("volume", ["volume": isMuted ? 0 : volume]) } } }
    var generation = 0
    var failedGeneration = -1
    var hasFailed: Bool { failedGeneration == generation }
    var sampledPosition = 0.0
    var sampledAt = 0.0
    var lastReportAt = 0.0
    var sampledLoading = false
    var didChange: (() -> Void)?
    var didEnd: (() -> Void)?
    var didFail: ((Error) -> Void)?
    var pending: [String: (Int, Date, (Result<Object, Error>) -> Void)] = [:]
    var observers: [NSObjectProtocol] = []
    var timer: Timer?
    override init() {
        super.init()
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("LXOwnAudioState"), object: nil, queue: .main) { [weak self] note in self?.receive(note.userInfo as? Object ?? [:]) })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("LXOwnAudioReply"), object: nil, queue: .main) { [weak self] note in
            guard let self=self, let value=note.userInfo as? Object, let item=self.pending.removeValue(forKey:text(value["ticket"])) else { return }
            guard item.0==self.generation else { return }
            let error=text(value["error"])
            item.2(error.isEmpty ? .success(value["value"] as? Object ?? [:]) : .failure(ClientError(error)))
        })
        // The Web UI interpolates the native clock between snapshots, so 1 Hz is enough
        // for authoritative correction and halves foreground bridge/probe traffic.
        let progressTimer=Timer(timeInterval:1.0, repeats:true) { [weak self] _ in
            guard let self=self else { return }
            for (id,item) in self.pending where item.1 < Date() { self.pending.removeValue(forKey:id); if item.0==self.generation { item.2(.failure(ClientError("原生播放核心响应超时，请重新打开 App"))) } }
            if let local = self.localAudio {
                self.sampledPosition = local.currentTime; self.sampledAt = Date().timeIntervalSince1970
                self.rate = local.isPlaying ? 1 : 0; self.timeControlStatus = local.isPlaying ? .playing : .paused
                self.didChange?()
            } else if self.currentItem != nil, !self.hasFailed {
                // Keep foreground UI snapshots flowing even if the asynchronous
                // decoder probe is delayed. currentTime() extrapolates from the
                // last known native clock until an authoritative sample arrives.
                if Date().timeIntervalSince1970 - self.lastReportAt > 1.25 { self.didChange?() }
                self.send("probe")
            }
        }
        timer=progressTimer;RunLoop.main.add(progressTimer,forMode:.common)
    }
    static func interpolatedPosition(sampledPosition: Double, sampledAt: Double, rate: Double, isPlaying: Bool, duration: Double, now: Double) -> Double {
        let base = sampledPosition.isFinite ? max(0, sampledPosition) : 0
        let safeRate = rate.isFinite ? max(0, rate) : 0
        let elapsed = now.isFinite && sampledAt.isFinite ? max(0, now - sampledAt) : 0
        let position = base + (isPlaying ? elapsed * safeRate : 0)
        return duration.isFinite && duration > 0 ? min(duration, position) : position
    }
    func currentTime() -> CMTime {
        if let local = localAudio { return CMTime(seconds: local.currentTime, preferredTimescale: 600) }
        let duration = currentItem?.duration.seconds ?? 0
        let position = Self.interpolatedPosition(sampledPosition: sampledPosition, sampledAt: sampledAt, rate: Double(rate), isPlaying: timeControlStatus == .playing, duration: duration, now: Date().timeIntervalSince1970)
        return CMTime(seconds: position, preferredTimescale: 600)
    }
    func receive(_ value:Object) {
        guard localAudio == nil, !hasFailed, Int(number(value["generation"],-1))==generation, currentItem != nil else { return }
        lastReportAt = Date().timeIntervalSince1970
        if let position=value["position"] { sampledPosition=max(0,number(position)); sampledAt=number(value["sampledAt"],Date().timeIntervalSince1970*1000)/1000 }
        if number(value["duration"])>0 { currentItem?.duration=CMTime(seconds:number(value["duration"]),preferredTimescale:600) }
        if value["playing"] != nil {
            rate=Float(number(value["rate"])); sampledLoading=bool(value["loading"])
            timeControlStatus=bool(value["playing"]) ? .playing : sampledLoading ? .waitingToPlayAtSpecifiedRate : .paused
        }
        let error=text(value["error"])
        if !error.isEmpty {
            failedGeneration=generation; rate=0; timeControlStatus = .paused; sampledLoading=false
            RuntimeTrace.record("audio.failure",["generation":generation,"error":error])
            didFail?(ClientError(error)); return
        }
        didChange?()
        if bool(value["ended"]) { didEnd?() }
    }
    func send(_ operation:String,_ args:Object=[:],completion:((Result<Object,Error>)->Void)?=nil) {
        let ticket=UUID().uuidString
        if let completion=completion { pending[ticket]=(generation,Date().addingTimeInterval(45),completion) }
        NotificationCenter.default.post(name:Notification.Name("LXOwnAudioCommand"),object:nil,userInfo:["ticket":ticket,"operation":operation,"generation":generation,"args":args])
    }
    func replaceCurrentItem(with unused: Item?, preservingNowPlaying: Bool = false) {
        localAudio?.stop(); localAudio?.delegate = nil; localAudio = nil
        generation += 1; pending.removeAll(); currentItem=nil; sampledPosition=0; sampledAt=Date().timeIntervalSince1970; lastReportAt=sampledAt; rate=0; timeControlStatus = .paused
        send(preservingNowPlaying ? "transition" : "clear")
    }
    func load(_ url:URL,song:Song,quality:String,position:Double,paused:Bool,completion:@escaping(Result<Object,Error>)->Void) {
        generation += 1; pending.removeAll(); currentItem=Item(); sampledPosition=position; sampledAt=Date().timeIntervalSince1970; lastReportAt=sampledAt; timeControlStatus = .waitingToPlayAtSpecifiedRate
        RuntimeTrace.record("audio.load",["generation":generation,"local":url.isFileURL,"paused":paused,"quality":quality])
        if url.isFileURL {
            do {
                // Open the actual on-device file. No web blob, remote URL or JS load is involved.
                let local = try AVAudioPlayer(contentsOf: url); local.delegate = self
                local.volume = isMuted ? 0 : volume; local.currentTime = min(max(0, position), local.duration)
                guard local.prepareToPlay() else { throw ClientError("无法解码本机音频，请重新下载") }
                localAudio = local; currentItem?.duration = CMTime(seconds: local.duration, preferredTimescale: 600)
                if !paused, !local.play() { throw ClientError("本机音频无法开始播放") }
                timeControlStatus = local.isPlaying ? .playing : .paused; rate = local.isPlaying ? 1 : 0
                completion(.success(["engine": "native-local-file"])); didChange?()
            } catch { localAudio = nil; completion(.failure(error)) }
            return
        }
        var artwork = text(song.raw["img"])
        if let cover = MusicLibrary.shared.coverURL(text(song.raw["offlineId"])) { artwork = cover.absoluteString }
        if artwork.hasPrefix("lx-local:") { artwork = "" }
        send("load",["url":url.absoluteString,"quality":quality,"title":song.name,"artist":song.artist,"album":text(song.raw["albumName"]),"artwork":artwork,"position":position,"paused":paused,"volume":isMuted ? 0 : volume],completion:completion)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard localAudio === player else { return }
        sampledPosition = player.duration; rate = 0; timeControlStatus = .paused; didChange?()
        if flag { didEnd?() } else { failLocal(ClientError("本机音频解码中断")) }
    }
    private func failLocal(_ error:Error) {
        guard !hasFailed else{return};failedGeneration=generation
        RuntimeTrace.record("audio.local-failure",["generation":generation,"error":error.localizedDescription])
        didFail?(error)
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard localAudio === player else{return};failLocal(error ?? ClientError("本机音频格式无法解码"))
    }
    func play() { if let local = localAudio { if local.play() { rate = 1; timeControlStatus = .playing; didChange?() }; return }; guard currentItem != nil else { return }; send("play"); timeControlStatus = .waitingToPlayAtSpecifiedRate }
    func pause() { if let local = localAudio { local.pause(); rate = 0; timeControlStatus = .paused; didChange?(); return }; sampledPosition=currentTime().seconds; sampledAt=Date().timeIntervalSince1970; rate=0; timeControlStatus = .paused; if currentItem != nil { send("pause") } }
    func seek(to time:CMTime,toleranceBefore:CMTime,toleranceAfter:CMTime,completionHandler:@escaping(Bool)->Void) {
        if let local = localAudio { local.currentTime = min(max(0,time.seconds),local.duration); didChange?(); completionHandler(true); return }
        sampledPosition=max(0,time.seconds); sampledAt=Date().timeIntervalSince1970
        send("seek",["position":sampledPosition]) { result in completionHandler((try? result.get()) != nil) }
    }
    // Publish on the native main queue. Lock-screen metadata must not wait for
    // a backgrounded RN queue or race decoder reset / asynchronous artwork.
    func metadata(_ value:Object) { NotificationCenter.default.post(name:Notification.Name("LXOwnNowPlaying"),object:nil,userInfo:value) }
    func clearMetadata() { NotificationCenter.default.post(name:Notification.Name("LXOwnNowPlayingClear"),object:nil) }
}
