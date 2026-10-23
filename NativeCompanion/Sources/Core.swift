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
// Monotonic time: wall clock corrections must not hide a dead room connection.
struct RoomConnectionHealth {
    var lastReceived = 0.0
    mutating func opened(at now: Double) { lastReceived = now }
    mutating func received(at now: Double) { lastReceived = now }
    func expired(at now: Double) -> Bool { now - lastReceived >= 20 }
}
enum RuntimeTrace {
    private static let lock = NSLock()
    private static let io = DispatchQueue(label:"net.minyue.lx.runtime-trace",qos:.utility)
    private static let process = UUID().uuidString
    private static var entries:[Object]=[]
    private static var loaded=false
    private static var scheduled=false
    private static var url:URL? { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first?.appendingPathComponent("LX-Runtime-Events.json") }
    static func record(_ event:String,_ fields:Object=[:]) {
        // Do not export account credentials, media URLs, lyrics or song names.
        var safe:Object=[:]
        for(key,value)in fields {
            if let s=value as? String {
                safe[key]=String(s.replacingOccurrences(of:"https?://\\S+",with:"[url]",options:.regularExpression).prefix(240))
            }else if value is NSNumber {safe[key]=value}
        }
        lock.lock()
        if !loaded {
            loaded=true
            if let file=url,let data=try? Data(contentsOf:file),let saved=(try? JSONSerialization.jsonObject(with:data)) as? [Object] {entries=Array(saved.suffix(80))}
        }
        entries.append(["at":Date().timeIntervalSince1970,"process":process,"event":event,"fields":safe])
        entries=Array(entries.suffix(100))
        let write = !scheduled;scheduled=true;lock.unlock()
        if write {io.asyncAfter(deadline:.now()+1) {
            lock.lock();let values=entries;scheduled=false;lock.unlock()
            if let file=url,let data=try? JSONSerialization.data(withJSONObject:values) {try? data.write(to:file,options:.atomic)}
        }}
    }
    static func snapshot()->[Object] {lock.lock();defer{lock.unlock()};return entries}
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
struct PlaybackEndGuard {
    var generation = -1
    var handled = false
    var position = 0.0
    var movedAt = 0.0
    mutating func reset(_ value: Int, now: Double) { generation = value; handled = false; position = 0; movedAt = now }
    mutating func claim(_ value: Int) -> Bool { guard generation == value, !handled else { return false }; handled = true; return true }
    mutating func stalledAtEnd(position value: Double, duration: Double, wanted: Bool, loading: Bool, seeking: Bool, playing: Bool, now: Double) -> Bool {
        if abs(value - position) > 0.03 || !wanted || loading || seeking || playing { position = value; movedAt = now; return false }
        return !handled && wanted && !loading && !seeking && duration > 2 && value >= duration - 0.65 && now - movedAt >= 4
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
        if !pendingID.isEmpty, other, rev <= revision { return false }
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

// CFNetwork owns the download temporary directory. Copy its file while the
// delegate callback is active; never rename/unlink a daemon-owned source file.
enum DownloadedAudioFile {
    static func allowBackgroundAccess(_ url: URL) throws {
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    static func persist(source: URL, directory: URL, name: String) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try allowBackgroundAccess(directory)
        let staging = directory.appendingPathComponent("." + UUID().uuidString + ".download")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        try allowBackgroundAccess(staging)
        let handle = try FileHandle(forReadingFrom: staging)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 256) ?? Data(), bytes = Array(head)
        let ext: String
        if head.starts(with: Data("fLaC".utf8)) { ext = "flac" }
        else if head.starts(with: Data("ID3".utf8)) { ext = "mp3" }
        else if bytes.count > 1 && bytes[0] == 0xff && bytes[1] & 0xf6 == 0xf0 { ext = "aac" }
        else if bytes.count > 1 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0 { ext = "mp3" }
        else if head.count >= 12 && head.subdata(in: 4..<8) == Data("ftyp".utf8) { ext = "m4a" }
        else if head.count >= 12 && head.starts(with: Data("RIFF".utf8)) && head.subdata(in: 8..<12) == Data("WAVE".utf8) { ext = "wav" }
        else if head.starts(with: Data("OggS".utf8)) { ext = "ogg" }
        else { throw ClientError("音源返回的不是音频文件，请更换音质或音源后重试") }
        let cleaned = name.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "音乐" : String(cleaned.prefix(90))
        let target = directory.appendingPathComponent(stem + "." + ext)
        if manager.fileExists(atPath: target.path) { _ = try manager.replaceItemAt(target, withItemAt: staging) }
        else { try manager.moveItem(at: staging, to: target) }
        return target
    }
}
