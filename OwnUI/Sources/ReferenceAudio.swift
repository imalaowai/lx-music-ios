import Foundation
import AVFoundation

// A transport adapter, not an AVPlayer. All sound is produced by the native
// TrackPlayer / streaming FLAC modules already present in the reference core.
final class ReferenceAudio {
    final class Item { var duration = CMTime.zero }
    var currentItem: Item?
    var timeControlStatus: AVPlayer.TimeControlStatus = .paused
    var rate: Float = 0
    var volume: Float = 1 { didSet { send("volume", ["volume": isMuted ? 0 : volume]) } }
    var isMuted = false { didSet { send("volume", ["volume": isMuted ? 0 : volume]) } }
    var generation = 0
    var sampledPosition = 0.0
    var sampledAt = 0.0
    var sampledLoading = false
    var didChange: (() -> Void)?
    var didEnd: (() -> Void)?
    var didFail: ((Error) -> Void)?
    var pending: [String: (Int, Date, (Result<Object, Error>) -> Void)] = [:]
    var observers: [NSObjectProtocol] = []
    var timer: Timer?
    init() {
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("LXOwnAudioState"), object: nil, queue: .main) { [weak self] note in self?.receive(note.userInfo as? Object ?? [:]) })
        observers.append(NotificationCenter.default.addObserver(forName: Notification.Name("LXOwnAudioReply"), object: nil, queue: .main) { [weak self] note in
            guard let self=self, let value=note.userInfo as? Object, let item=self.pending.removeValue(forKey:text(value["ticket"])) else { return }
            guard item.0==self.generation else { return }
            let error=text(value["error"])
            item.2(error.isEmpty ? .success(value["value"] as? Object ?? [:]) : .failure(ClientError(error)))
        })
        timer=Timer.scheduledTimer(withTimeInterval:0.5, repeats:true) { [weak self] _ in
            guard let self=self else { return }
            for (id,item) in self.pending where item.1 < Date() { self.pending.removeValue(forKey:id); if item.0==self.generation { item.2(.failure(ClientError("原生播放核心响应超时，请重新打开 App"))) } }
            if self.currentItem != nil { self.send("probe") }
        }
    }
    func currentTime() -> CMTime {
        let advance=timeControlStatus == .playing ? min(1.5,max(0,Date().timeIntervalSince1970-sampledAt))*Double(rate) : 0
        let duration=currentItem?.duration.seconds ?? 0
        return CMTime(seconds:duration>0 ? min(duration,sampledPosition+advance) : sampledPosition+advance, preferredTimescale:600)
    }
    func receive(_ value:Object) {
        guard Int(number(value["generation"],-1))==generation, currentItem != nil else { return }
        if let position=value["position"] { sampledPosition=max(0,number(position)); sampledAt=number(value["sampledAt"],Date().timeIntervalSince1970*1000)/1000 }
        if number(value["duration"])>0 { currentItem?.duration=CMTime(seconds:number(value["duration"]),preferredTimescale:600) }
        if value["playing"] != nil {
            rate=Float(number(value["rate"])); sampledLoading=bool(value["loading"])
            timeControlStatus=bool(value["playing"]) ? .playing : sampledLoading ? .waitingToPlayAtSpecifiedRate : .paused
        }
        let error=text(value["error"])
        if !error.isEmpty { didFail?(ClientError(error)); return }
        didChange?()
        if bool(value["ended"]) { didEnd?() }
    }
    func send(_ operation:String,_ args:Object=[:],completion:((Result<Object,Error>)->Void)?=nil) {
        let ticket=UUID().uuidString
        if let completion=completion { pending[ticket]=(generation,Date().addingTimeInterval(45),completion) }
        NotificationCenter.default.post(name:Notification.Name("LXOwnAudioCommand"),object:nil,userInfo:["ticket":ticket,"operation":operation,"generation":generation,"args":args])
    }
    func replaceCurrentItem(with unused: Item?) {
        generation += 1; pending.removeAll(); currentItem=nil; sampledPosition=0; sampledAt=Date().timeIntervalSince1970; rate=0; timeControlStatus = .paused
        send("clear")
    }
    func load(_ url:URL,song:Song,quality:String,position:Double,paused:Bool,completion:@escaping(Result<Object,Error>)->Void) {
        generation += 1; pending.removeAll(); currentItem=Item(); sampledPosition=position; sampledAt=Date().timeIntervalSince1970; timeControlStatus = .waitingToPlayAtSpecifiedRate
        send("load",["url":url.absoluteString,"quality":quality,"title":song.name,"artist":song.artist,"album":text(song.raw["albumName"]),"artwork":text(song.raw["img"]),"position":position,"paused":paused,"volume":isMuted ? 0 : volume],completion:completion)
    }
    func play() { guard currentItem != nil else { return }; send("play"); timeControlStatus = .waitingToPlayAtSpecifiedRate }
    func pause() { sampledPosition=currentTime().seconds; sampledAt=Date().timeIntervalSince1970; rate=0; timeControlStatus = .paused; if currentItem != nil { send("pause") } }
    func seek(to time:CMTime,toleranceBefore:CMTime,toleranceAfter:CMTime,completionHandler:@escaping(Bool)->Void) {
        sampledPosition=max(0,time.seconds); sampledAt=Date().timeIntervalSince1970
        send("seek",["position":sampledPosition]) { result in completionHandler((try? result.get()) != nil) }
    }
    func metadata(_ value:Object) { send("metadata",value) }
}
