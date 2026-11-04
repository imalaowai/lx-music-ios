import Foundation

// Compile the production RoomClient with a deterministic audio/API boundary.
// Network and audio timing can be controlled without running phone JavaScript.
struct Credentials { var token = "fixture" }
final class API {
    var credentials: Credentials? = Credentials()
    let session = URLSession.shared
    var requests: [(String, Object)] = []
    var respond: (String, Object) -> Result<Object, Error> = { _, _ in .success([:]) }
    func url(_ path: String) -> URL? { nil }
    func request(_ path: String, method: String = "GET", body: Object? = nil, completion: @escaping (Result<Object, Error>) -> Void) {
        requests.append((path, body ?? [:])); completion(respond(path, body ?? [:]))
    }
}
final class TestAudio { var currentItem: NSObject? = NSObject() }
final class Player {
    let api = API(), audio = TestAudio()
    var queue = [Song(raw:["id":"A","songmid":"rawA","source":"wy","name":"A"])]
    var index = 0, queueRevision = 0, generation = 1
    var mode = "list", failure = "", routeGate = PlaybackRouteGate(), endGuard = PlaybackEndGuard()
    var wanted = true, loading = false
    var position = 10.0, duration = 180.0
    var seeks: [Double] = []
    var selections = 0
    var onRoom: ((Object) -> Void)?, onRevoked: (() -> Void)?, onChat: ((String, Object) -> Void)?
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    func select(_ songs: [Song], index: Int, paused: Bool, user: Bool, time: Double) { queue = songs; self.index = index; wanted = !paused; position = time; selections += 1; generation += 1 }
    func seek(_ time: Double, user: Bool) { seeks.append(time); position = time }
    func play(user: Bool) { wanted = true }
    func pause(user: Bool) { wanted = false }
    func configure(_ value: Credentials?) { api.credentials = value }
    func finishTransition() {}
    func publish() {}
    func fail(_ error: Error) { failure = error.localizedDescription; wanted = false }
}

@main enum RoomRecoveryChecks {
    static var checks: [String: Bool] = [:]
    static func check(_ condition: Bool, _ name: String) { checks[name] = condition; if !condition { fatalError(name) } }
    static func incoming(_ player: Player, revision: Int = 1) -> Object {
        ["song":player.current!.raw,"songKey":"server-negotiated-key","playlist":player.queue.map(\.raw),"index":player.index,"reason":"progress","revision":revision,"playbackRevision":7,"paused":false,"currentTime":70,"updatedAt":Date().timeIntervalSince1970*1000,"controllerId":"me"]
    }
    static func main() {
        let p = Player(), room = RoomClient(player:p)
        room.binding = ["roomId":"fixture"]; room.participantID = "me"
        room.needsSnapshotSync = true; room.apply(incoming(p))
        check(p.seeks.count == 1 && p.position >= 70 && p.position < 72, "reconnect corrects a missed seek even when the latest event is progress")
        check(p.selections == 0, "same-song recovery retains the existing decoder")
        room.apply(incoming(p,revision:2)); check(p.seeks.count == 1, "routine progress does not repeatedly seek")
        p.wanted = false; room.needsSnapshotSync = true; room.apply(incoming(p,revision:3))
        check(p.wanted, "an authoritative playing snapshot restores missed playback intent")
        p.routeGate.suspend(); p.wanted = false; room.needsSnapshotSync = true; room.apply(incoming(p,revision:4))
        check(!p.wanted, "reconnect cannot release the output-loss pause hold")
        p.routeGate.resumeByUser(); p.wanted = true
        room.connected = true; room.health.received(at:ProcessInfo.processInfo.systemUptime)
        room.heartbeat(); check(room.lastProgressAt > 0, "native heartbeat publishes progress without an audio or WebKit callback")
        check(room.wireSongKey(p.current!) == "server-negotiated-key", "telemetry uses the server key for old and new server compatibility")
        room.mediaReady()
        let metadata = p.api.requests.last!.1
        check(text(metadata["songKey"]) == "server-negotiated-key" && number(metadata["playbackRevision"]) == 7, "media-ready telemetry includes song identity and playback revision")

        p.api.respond = { _, _ in .failure(ClientError("temporary network loss")) }
        room.sendState(reason:"track")
        check(room.order.pendingID.isEmpty && room.needsSnapshotSync, "a failed track command releases its pending acknowledgement fence")
        check(room.outgoing.isEmpty && !room.sending, "failed control requests cannot deadlock later controls")
        check(p.failure.isEmpty && !room.lastError.isEmpty, "a room HTTP failure does not fail a healthy audio decoder")
        room.order.pendingID = "newer"; room.order.pendingKey = "A"
        room.exchange(["type":"room:state","state":["commandId":"older"]])
        check(room.order.pendingID == "newer", "an older HTTP failure cannot cancel a newer user command")

        let retryPlayer = Player(), retryRoom = RoomClient(player:retryPlayer)
        var bindings = 0
        retryPlayer.api.respond = { path, _ in
            if path == "/api/room/binding" { bindings += 1; if bindings == 1 { return .failure(ClientError("offline at wake")) } }
            return .success([:])
        }
        retryRoom.refresh()
        check(retryRoom.refreshRetry != nil && bindings == 1, "initial binding failure schedules recovery without opening the phone UI")
        let deadline = Date().addingTimeInterval(2)
        while bindings < 2 && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        check(bindings == 2 && retryRoom.lastError.isEmpty, "the scheduled binding retry restores room discovery")
        retryRoom.disconnect(clear:true); room.disconnect(clear:true)
        print(String(data:try! JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
