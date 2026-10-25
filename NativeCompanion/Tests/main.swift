import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
check(QueuePolicy.next(count: 3, index: 2, mode: "list") == 0, "list wraps")
check(QueuePolicy.next(count: 3, index: 2, mode: "order") == nil, "order stops")
check(QueuePolicy.next(count: 3, index: 0, mode: "list", previous: true) == 2, "previous wraps")
check(QueuePolicy.next(count: 3, index: 1, mode: "single", automatic: true) == 1, "single repeats on EOF")
check(QueuePolicy.next(count: 0, index: -1, mode: "list") == nil, "empty queue does not play")
var order = RoomOrder()
order.pendingID = "newer"; order.pendingKey = "C"
check(!order.accept(["revision": 5, "controllerId": "me", "commandId": "older", "songKey": "B"], participant: "me"), "late own track ACK must not rewind C to B")
check(order.accept(["revision": 6, "controllerId": "me", "commandId": "newer", "songKey": "C"], participant: "me"), "current track ACK accepted")
check(!order.accept(["revision": 4, "controllerId": "other", "songKey": "A"], participant: "me"), "stale remote revision rejected")
order.pendingID = "pending"; order.pendingKey = "D"
check(!order.accept(["revision": 6, "controllerId": "other", "songKey": "old"], participant: "me"), "an already observed snapshot cannot cancel a new local track")
check(order.accept(["revision": 7, "controllerId": "other", "commandId": "remote", "songKey": "X"], participant: "me"), "new explicit controller may supersede a local pending command")
let base = URL(string: "https://music.invalid:99/custom/")!
let upstream = "https://cdn.invalid/audio.flac?signature=a%2Fb"
let proxy = "/api/music/download?url=" + upstream.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
check(try! MediaAddress.direct(proxy, base: base).absoluteString == upstream, "restore original CDN without losing signature")
check(try! MediaAddress.direct("/api/openlist/stream?ticket=owned", base: base).absoluteString == "https://music.invalid:99/api/openlist/stream?ticket=owned", "preserve explicit OpenList permission route")
do { _ = try MediaAddress.direct("javascript:alert(1)", base: base); fatalError("unsafe scheme accepted") } catch {}
do { _ = try MediaAddress.direct("/api/music/download?url=javascript%3Aalert(1)", base: base); fatalError("unsafe nested source accepted") } catch {}
print("Native queue ordering, room race handling and direct-media policy passed.")

var ending = PlaybackEndGuard()
ending.reset(3, now: 0)
check(!ending.claim(2), "old item EOF cannot advance current track")
check(ending.claim(3), "current item EOF advances once")
check(!ending.claim(3), "duplicate EOF cannot skip the following track")
ending.reset(4, now: 0)
check(!ending.stalledAtEnd(position: 179.7, duration: 180, wanted: true, loading: false, seeking: false, playing: false, now: 1), "new position starts the stall deadline")
check(!ending.stalledAtEnd(position: 179.7, duration: 180, wanted: true, loading: false, seeking: false, playing: false, now: 4.9), "tail is given time to finish")
check(ending.stalledAtEnd(position: 179.7, duration: 180, wanted: true, loading: false, seeking: false, playing: false, now: 5.1), "missing EOF recovers a stalled last second")
check(!ending.stalledAtEnd(position: 179.7, duration: 180, wanted: false, loading: false, seeking: false, playing: false, now: 10), "manual pause never advances")
check(!ending.stalledAtEnd(position: 179.7, duration: 180, wanted: true, loading: false, seeking: true, playing: false, now: 20), "seek does not trigger EOF recovery")
check(!ending.stalledAtEnd(position: 100, duration: 180, wanted: true, loading: false, seeking: false, playing: false, now: 30), "network stall in middle is not EOF")
check(!ending.stalledAtEnd(position: 100, duration: 180, wanted: true, loading: false, seeking: false, playing: false, now: 40), "middle stall remains current track")
print("EOF deduplication and missing-notification recovery passed.")

var health=RoomConnectionHealth()
health.opened(at:100)
check(!health.expired(at:119.99),"healthy socket gets its heartbeat grace period")
check(health.expired(at:120),"silent half-open socket must recover without phone activation")
health.received(at:121)
check(!health.expired(at:140),"received room messages renew connection health")
health.opened(at:150)
check(!health.expired(at:151),"new connection does not inherit an expired deadline")
RuntimeTrace.record("test.redaction",["error":"failed https://private.invalid/audio?token=secret","generation":3])
let trace=RuntimeTrace.snapshot()
check(!String(describing:trace).contains("token=secret"),"runtime trace never records media credentials")
print("Room heartbeat recovery and runtime redaction passed.")

// A download must preserve the system-owned source and reject error documents.
do {
    let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("CFNetworkDownload.tmp"), directory = root.appendingPathComponent("Music")
    let audio = Data("fLaC".utf8) + Data(repeating: 0, count: 128)
    try audio.write(to: source)
    let saved = try DownloadedAudioFile.persist(source: source, directory: directory, name: "离线/歌曲")
    check(manager.fileExists(atPath: source.path), "never unlink the CFNetwork temporary source")
    let savedBytes = try Data(contentsOf: saved)
    check(savedBytes == audio, "copy the complete audio bytes into app-owned storage")
    check(saved.lastPathComponent == "离线_歌曲.flac", "filename cannot escape the song directory")
    try Data("{\"error\":\"expired source\"}".utf8).write(to: source)
    do { _ = try DownloadedAudioFile.persist(source: source, directory: directory, name: "invalid"); fatalError("saved a JSON error as audio") } catch {}
    let files = try manager.contentsOfDirectory(atPath: directory.path)
    check(files == [saved.lastPathComponent], "failed downloads leave no staging file")
    print("Download source ownership, file signatures and staging cleanup passed.")
} catch { fatalError("Download persistence regression: \(error)") }

var outputGate = PlaybackRouteGate()
check(outputGate.permitsPlayback(user:false), "ordinary room playback is permitted before output loss")
outputGate.suspend()
check(!outputGate.permitsPlayback(user:false), "room sync and interruption recovery cannot release an output-loss hold")
check(outputGate.permitsPlayback(user:true), "an explicit play can authorize phone output")
let heldEpoch=outputGate.epoch
outputGate.resumeByUser()
check(!outputGate.held && outputGate.epoch>heldEpoch, "only explicit user playback clears the route hold")
var roomTie=RoomOrder()
check(roomTie.accept(["revision":12,"songKey":"A"],participant:"me"), "room initial track accepted")
check(!roomTie.accept(["revision":12,"songKey":"B"],participant:"me"), "equal-revision snapshots cannot switch to another song")
check(roomTie.accept(["revision":13,"songKey":"B"],participant:"me"), "a newer room track is still accepted")
print("Local output-loss gate and room revision ties passed.")
