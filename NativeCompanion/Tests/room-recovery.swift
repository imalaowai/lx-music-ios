import Foundation
extension Notification.Name { static let lxRoom = Notification.Name("LXNativeRoom") }

// Compile the production RoomClient with a deterministic audio/API boundary.
// Network and audio timing can be controlled without running phone JavaScript.
struct Credentials { var token = "fixture" }
final class API {
    var credentials: Credentials? = Credentials()
    let session = URLSession.shared
    var requests: [(String, Object)] = []
    var postpone = false
    var deferred: [(Result<Object, Error>) -> Void] = []
    var respond: (String, Object) -> Result<Object, Error> = { _, _ in .success([:]) }
    func url(_ path: String) -> URL? { nil }
    func request(_ path: String, method: String = "GET", body: Object? = nil, timeout: TimeInterval? = nil, completion: @escaping (Result<Object, Error>) -> Void) {
        requests.append((path, body ?? [:])); if postpone { deferred.append(completion) } else { completion(respond(path, body ?? [:])) }
    }
}
final class TestAudio { var currentItem: NSObject? = NSObject() }
final class Player {
    let api = API(), audio = TestAudio()
    var queue = [Song(raw:["id":"A","songmid":"rawA","source":"wy","name":"A"])]
    var index = 0, queueRevision = 0, generation = 1
    var mode = "list", failure = "", routeGate = PlaybackRouteGate(), endGuard = PlaybackEndGuard()
    var wanted = true, loading = false, seeking = false
    var clockPlaying = true
    var playbackAdvancing: Bool { wanted && !loading && !seeking && !endGuard.handled && clockPlaying }
    var position = 10.0, duration = 180.0
    var seeks: [Double] = []
    var selections = 0
    var onRoom: ((Object) -> Void)?, onRevoked: (() -> Void)?, onChat: ((String, Object) -> Void)?
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    func select(_ songs: [Song], index: Int, paused: Bool, user: Bool, time: Double, reuseQueue: Bool = false) { if !reuseQueue { queue = songs; queueRevision += 1 }; self.index = index; wanted = !paused; position = time; selections += 1; generation += 1 }
    func seek(_ time: Double, user: Bool) { seeks.append(time); position = time }
    func play(user: Bool) { wanted = true }
    func pause(user: Bool) { wanted = false }
    func revokeSession() {
        guard api.credentials != nil else { return }
        api.credentials = nil
        onRevoked?()
    }
    func finishTransition() {}
    func persistQueue() {}
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
        check(p.failure.isEmpty && !room.commandError.isEmpty, "a room HTTP failure does not fail a healthy audio decoder")
        room.order.pendingID = "newer"; room.order.pendingKey = "A"
        room.exchange(["type":"room:state","state":["commandId":"older"]])
        check(room.order.pendingID == "newer", "an older HTTP failure cannot cancel a newer user command")
        room.order.pendingID = "rejected"; room.order.pendingKey = "A"
        p.api.respond = { _, _ in .success(["accepted":false,"state":incoming(p,revision:5)]) }
        room.exchange(["type":"room:state","state":["commandId":"rejected"]])
        check(room.order.pendingID.isEmpty && room.order.revision == 5, "a rejected control immediately reconciles the returned authoritative snapshot")
        p.endGuard.reset(p.generation,now:0); _ = p.endGuard.claim(p.generation)
        room.needsSnapshotSync = true; room.apply(incoming(p,revision:6))
        check(p.selections == 1, "rejoining an ongoing song repairs a locally ended decoder")
        let delayed = Player(), delayedRoom = RoomClient(player:delayed)
        delayedRoom.binding = ["roomId":"delayed"]; delayedRoom.state = incoming(delayed)
        delayedRoom.mediaReady()
        check(delayed.seeks.count == 1 && delayed.position >= 70, "decoder readiness compensates for elapsed source-resolution time")
        delayed.position = 10; delayed.seeking = true; delayedRoom.mediaReady()
        check(delayed.seeks.count == 1, "decoder readiness cannot supersede an in-flight user seek")
        delayedRoom.connected = true; delayedRoom.participantID = "me"; delayedRoom.progress()
        check(delayedRoom.lastProgressAt == -.infinity, "an unfinished seek cannot publish stale progress to the room")
        delayedRoom.disconnect(clear:true)

        let jitter = Player(), jitterRoom = RoomClient(player:jitter)
        jitterRoom.binding = ["roomId":"jitter"]; jitterRoom.participantID = "me"
        jitterRoom.apply(incoming(jitter))
        jitter.position = 71.4
        jitterRoom.needsSnapshotSync = true
        jitterRoom.apply(incoming(jitter,revision:2))
        check(jitter.seeks.isEmpty, "reconnecting cannot rewind the running controller to its old progress")
        var seek = incoming(jitter,revision:3)
        seek["reason"] = "seek"; seek["playbackRevision"] = 8; seek["controllerId"] = "friend"
        jitterRoom.apply(seek)
        jitterRoom.needsSnapshotSync = true; jitterRoom.apply(seek)
        check(jitter.seeks.count == 1, "a new seek from another listener applies once across duplicate socket and HTTP snapshots")
        jitterRoom.disconnect(clear:true)

        let echoPlayer = Player(), echoRoom = RoomClient(player:echoPlayer)
        echoRoom.binding = ["roomId":"seek-echo"]; echoRoom.participantID = "me"
        echoRoom.apply(incoming(echoPlayer))
        echoPlayer.api.postpone = true
        echoRoom.sendState(reason:"seek", position:70)
        echoPlayer.position = 71.4
        var echo = incoming(echoPlayer,revision:2)
        echo["reason"] = "seek"; echo["playbackRevision"] = 8
        echoRoom.apply(echo)
        echoPlayer.api.deferred.removeFirst()(.success(["accepted":true,"state":echo,"participantId":"me"]))
        check(echoPlayer.seeks.isEmpty, "local seeks are not executed again when both transports acknowledge them")
        echo["revision"] = 3; echo["playbackRevision"] = 9
        echoRoom.apply(echo)
        check(echoPlayer.seeks.count == 1, "a different device on the same account can still send a new seek")
        echoRoom.connected = true
        echoPlayer.clockPlaying = false; echoRoom.progress()
        check(echoRoom.lastProgressAt == -.infinity, "a buffering decoder does not publish running progress to the room")
        echoPlayer.clockPlaying = true; echoRoom.progress()
        check(echoRoom.lastProgressAt > 0, "room progress resumes when the decoder advances again")
        echoRoom.disconnect(clear:true)

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
        let changedPlayer = Player(), changedRoom = RoomClient(player:changedPlayer)
        changedRoom.binding = ["roomId":"old-room"]
        changedPlayer.api.respond = { path, _ in .success(path == "/api/room/binding" ? ["binding":["roomId":"current-room"]] : [:]) }
        changedRoom.recoverConnection("carplay-connected")
        check(changedRoom.roomID == "current-room", "CarPlay wake rechecks the account binding instead of reconnecting a stale room forever")
        changedRoom.disconnect(clear:true)
        let rapid = Player(), rapidRoom = RoomClient(player:rapid)
        rapidRoom.binding = ["roomId":"rapid"]; rapid.api.postpone = true
        rapidRoom.sendState(reason:"track")
        rapid.queue = [Song(raw:["id":"B"])]; rapidRoom.sendState(reason:"track")
        rapid.queue = [Song(raw:["id":"C"])]; rapidRoom.sendState(reason:"track")
        check(rapidRoom.outgoing.count == 1 && text((rapidRoom.outgoing[0].0["state"] as? Object)?["songKey"]) == "C", "network recovery keeps the latest queued selection instead of replaying old tracks")
        rapid.api.deferred.removeFirst()(.failure(ClientError("first request timed out")))
        check(rapid.api.requests.count == 2 && text((rapid.api.requests.last!.1["state"] as? Object)?["songKey"]) == "C", "the latest queued selection drains after the old in-flight request finishes")
        rapidRoom.disconnect(clear:true)

        let cold = Player(), coldRoom = RoomClient(player:cold)
        cold.wanted = false; cold.audio.currentItem = nil; cold.api.postpone = true
        let firstTap = Song(raw:["id":"first-tap","source":"wy"]), lastTap = Song(raw:["id":"last-tap","source":"wy"])
        func tap(_ song: Song) {
            coldRoom.afterInitialBinding {
                cold.select([song], index:0, paused:false, user:true, time:0)
                coldRoom.sendState(reason:"track")
            }
        }
        coldRoom.recoverConnection("carplay-connected")
        tap(firstTap); tap(lastTap)
        check(cold.api.requests.count == 2 && cold.current?.key == "A", "cold CarPlay taps wait for the in-flight account binding check")
        cold.api.deferred.removeLast()(.success(["binding":["roomId":"cold-room"]]))
        check(cold.api.requests.count == 2 && cold.selections == 0, "binding waits for the synchronization configuration even when it arrives first")
        cold.api.deferred.removeFirst()(.success([:]))
        check(coldRoom.roomID == "cold-room" && text(cold.api.requests.last!.1["type"]) == "room:sync-request" && cold.selections == 0,
              "cold CarPlay restores a room through HTTP before the socket connects")
        let beforeTap = incoming(cold,revision:9)
        cold.api.deferred.removeFirst()(.success(["state":beforeTap,"participantId":"me"]))
        check(cold.selections == 2 && cold.current?.key == lastTap.key, "initial room snapshot is followed only by the latest explicit CarPlay tap")
        check(text(cold.api.requests.last!.1["roomId"]) == "cold-room" &&
              text((cold.api.requests.last!.1["state"] as? Object)?["songKey"]) == lastTap.key,
              "a cold CarPlay tap broadcasts its track to the restored room")
        coldRoom.apply(beforeTap)
        check(cold.current?.key == lastTap.key, "an old startup snapshot cannot replace the pending CarPlay track")
        coldRoom.disconnect(clear:true)

        let opening = Player(), openingRoom = RoomClient(player:opening)
        openingRoom.binding = ["roomId":"dual-transport"]; opening.audio.currentItem = nil
        let firstSnapshot = incoming(opening,revision:3)
        openingRoom.apply(firstSnapshot)
        opening.loading = true
        openingRoom.apply(firstSnapshot)
        check(opening.selections == 1, "the duplicate HTTP and WebSocket startup snapshot cannot restart a resolving song")
        openingRoom.disconnect(clear:true)

        let off = Player(), offRoom = RoomClient(player:off)
        off.api.postpone = true
        var standalone = false
        offRoom.afterInitialBinding { standalone = !offRoom.active }
        off.api.deferred.removeLast()(.success(["binding":["roomId":"configured-room"]]))
        off.api.deferred.removeFirst()(.success(["room.syncOnTrack":false]))
        check(standalone && off.api.requests.count == 2, "disabled room synchronization preserves local CarPlay playback")
        offRoom.disconnect(clear:true)
        standalone = false
        offRoom.afterInitialBinding { standalone = true }
        offRoom.cancelCarPlayAction()
        off.api.deferred.removeLast()(.success(["binding":NSNull()]))
        off.api.deferred.removeFirst()(.success([:]))
        check(!standalone, "disconnecting CarPlay drops a tap still waiting for room discovery")

        let paused = Player(), pausedRoom = RoomClient(player:paused)
        paused.wanted = false; paused.audio.currentItem = nil; pausedRoom.binding = ["roomId":"empty"]
        pausedRoom.handle("room:joined", ["state":["song":NSNull()]])
        check(paused.api.requests.isEmpty, "cold room join does not broadcast an old paused queue to an empty room")
        let evicted = Player(), evictedRoom = RoomClient(player:evicted)
        var notices = 0
        evicted.onRevoked = {
            check(evicted.api.credentials == nil, "session credentials are cleared before the room notifies the page")
            notices += 1
        }
        evictedRoom.handle("room:session-evicted", nil)
        evictedRoom.handle("room:session-evicted", nil)
        check(notices == 1, "a duplicate eviction cannot restart the logout flow")
        offRoom.disconnect(clear:true); pausedRoom.disconnect(clear:true)
        retryRoom.disconnect(clear:true); room.disconnect(clear:true)
        print(String(data:try! JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
