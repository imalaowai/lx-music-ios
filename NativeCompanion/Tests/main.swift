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
check(order.accept(["revision": 7, "controllerId": "other", "commandId": "remote", "songKey": "X"], participant: "me"), "new explicit controller may supersede a local pending command")
let base = URL(string: "https://music.invalid:99/custom/")!
let upstream = "https://cdn.invalid/audio.flac?signature=a%2Fb"
let proxy = "/api/music/download?url=" + upstream.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
check(try! MediaAddress.direct(proxy, base: base).absoluteString == upstream, "restore original CDN without losing signature")
check(try! MediaAddress.direct("/api/openlist/stream?ticket=owned", base: base).absoluteString == "https://music.invalid:99/api/openlist/stream?ticket=owned", "preserve explicit OpenList permission route")
do { _ = try MediaAddress.direct("javascript:alert(1)", base: base); fatalError("unsafe scheme accepted") } catch {}
do { _ = try MediaAddress.direct("/api/music/download?url=javascript%3Aalert(1)", base: base); fatalError("unsafe nested source accepted") } catch {}
print("Native queue ordering, room race handling and direct-media policy passed.")
