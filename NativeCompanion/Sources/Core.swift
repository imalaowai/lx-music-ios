import Foundation

typealias Object = [String: Any]
func number(_ value: Any?, _ fallback: Double = 0) -> Double { (value as? NSNumber)?.doubleValue ?? fallback }
func text(_ value: Any?) -> String { value as? String ?? "" }
func bool(_ value: Any?, _ fallback: Bool = false) -> Bool { (value as? NSNumber)?.boolValue ?? fallback }
struct ClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
struct Song {
    var raw: Object
    var key: String { for k in ["songmid", "mid", "id"] { if let v = raw[k], !(v is NSNull) { return String(describing: v) } }; return name + "-" + artist }
    var name: String { text(raw["name"]) }
    var artist: String { text(raw["singer"]).isEmpty ? text(raw["artist"]) : text(raw["singer"]) }
}
enum QueuePolicy {
    static func next(count: Int, index: Int, mode: String, previous: Bool = false, automatic: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        if mode == "single", automatic { return max(0, min(index, count - 1)) }
        if mode == "random", count > 1 { return (index + Int.random(in: 1..<count)) % count }
        let target = index + (previous ? -1 : 1)
        if mode == "order", !previous, target >= count { return nil }
        return (target + count) % count
    }
}
struct RoomOrder {
    var revision = -1.0
    var pendingID = ""
    var pendingKey = ""
    mutating func accept(_ state: Object, participant: String) -> Bool {
        let rev = number(state["revision"], -1)
        guard rev >= revision else { return false }
        let controller = text(state["controllerId"])
        let key = (state["song"] as? Object).map { Song(raw: $0).key } ?? text(state["songKey"])
        let command = text(state["commandId"])
        let other = !controller.isEmpty && controller != participant
        if !pendingID.isEmpty, !other {
            if !command.isEmpty && command != pendingID { return false }
            if command.isEmpty && key != pendingKey { return false }
        }
        if other || command == pendingID { pendingID = ""; pendingKey = "" }
        revision = rev
        return true
    }
}
enum MediaAddress {
    static func direct(_ input: String, base: URL) throws -> URL {
        guard var url = URL(string: input, relativeTo: base)?.absoluteURL else { throw ClientError("音源地址无效") }
        for _ in 0..<4 {
            guard url.host == base.host, url.port == base.port, url.path == "/api/music/download" else { break }
            guard let source = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {$0.name == "url"})?.value,
                  let next = URL(string: source), ["http", "https"].contains(next.scheme?.lowercased() ?? "") else { throw ClientError("代理地址缺少原音源") }
            url = next
        }
        guard ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else { throw ClientError("该音源不能由原生播放器直接读取") }
        guard !(url.host == base.host && url.port == base.port && url.path == "/api/music/download") else { throw ClientError("代理地址嵌套过多") }
        return url
    }
}
