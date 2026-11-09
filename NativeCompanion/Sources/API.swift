import Foundation
import Security

struct Credentials: Codable, Equatable {
    var server: String
    var username: String
    var token: String
    var url: URL? { URL(string: server) }
}
enum Vault {
    static let service = "net.minyue.lxcompanion"
    static let webSessionMigratedKey = "lx.webSessionMigrated"
    static func load() -> Credentials? {
        let query: Object = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }
    static func save(_ credentials: Credentials?) {
        let query: Object = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
        SecItemDelete(query as CFDictionary)
        guard let credentials = credentials, let data = try? JSONEncoder().encode(credentials) else { return }
        var record = query
        record[kSecValueData as String] = data
        record[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(record as CFDictionary, nil)
    }
}
private final class DirectServerRequest: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct ServerSessionExpired: LocalizedError {
    var errorDescription: String? { "账号登录已失效，请重新登录" }
}

final class API {
    var credentials: Credentials? {
        didSet {
            guard credentials != oldValue else { return }
            sessionRevision += 1
            sourceCache.removeAll()
        }
    }
    private var sessionRevision = 0
    var onSessionExpired: (() -> Void)?
    var sourceCache: [String: (ResolvedAudio, Date)] = [:]
    let session: URLSession
    #if LX_OWN_UI_TESTING
    static var fixtureProtocol: AnyClass?
    #endif
    private lazy var directSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        #if LX_OWN_UI_TESTING
        if let fixture = Self.fixtureProtocol { configuration.protocolClasses = [fixture] }
        #endif
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: DirectServerRequest(), delegateQueue: nil)
    }()
    init() {
        credentials = Vault.load()
        let configuration = URLSessionConfiguration.default
        #if LX_OWN_UI_TESTING
        if let fixture = Self.fixtureProtocol { configuration.protocolClasses = [fixture] }
        #endif
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }
    var base: URL? { credentials?.url }
    func url(_ path: String) -> URL? { guard let base = base else { return nil }; return URL(string: path, relativeTo: base)?.absoluteURL }
    @discardableResult func request(_ path: String, method: String = "GET", body: Object? = nil, timeout: TimeInterval? = nil, completion: @escaping (Result<Object, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = url(path), let identity = credentials else { completion(.failure(ClientError("请先打开手机页面登录音乐账号"))); return nil }
        let revision = sessionRevision
        return requestJSON(url, via: session, method: method, body: body, timeout: timeout, identity: identity) { [weak self] result in
            guard let self = self, self.sessionRevision == revision else { completion(.failure(URLError(.cancelled))); return }
            if case .failure(let error) = result, error is ServerSessionExpired { self.onSessionExpired?() }
            completion(result)
        }
    }
    @discardableResult func requestServer(_ base: URL, path: String, body: Object, timeout: TimeInterval,
                                          completion: @escaping (Result<Object, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            completion(.failure(ClientError("服务器地址无效"))); return nil
        }
        return requestJSON(url, via: directSession, method: "POST", body: body, timeout: timeout, identity: nil, completion: completion)
    }
    private func requestJSON(_ url: URL, via transport: URLSession, method: String, body: Object?, timeout: TimeInterval?,
                             identity: Credentials?, completion: @escaping (Result<Object, Error>) -> Void) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout = timeout { request.timeoutInterval = timeout }
        request.setValue(identity?.token, forHTTPHeaderField: "x-user-token")
        request.setValue(identity?.username, forHTTPHeaderField: "x-user-name")
        if let body = body { request.httpBody = try? JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let task = transport.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let value = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? Object }
            var result: Result<Object, Error>
            if let error = error { result = .failure(error) }
            else if code == 401, identity != nil,
                    text(value?["code"]) == "AUTH_REQUIRED" || ["/api/music/url", "/api/user/list", "/api/room/binding"].contains(url.path) {
                result = .failure(ServerSessionExpired())
            }
            else if let value = value {
                if (200..<300).contains(code), value["success"] == nil || bool(value["success"]) { result = .success(value) }
                else { result = .failure(ClientError(text(value["message"]).isEmpty ? (text(value["error"]).isEmpty ? "请求失败（\(code)）" : text(value["error"])) : text(value["message"]))) }
            } else { result = .failure(ClientError("服务返回了无法读取的数据")) }
            let response = result
            DispatchQueue.main.async { completion(response) }
        }
        task.resume()
        return task
    }
    func cacheKey(_ song: Song, _ quality: String, _ allowFallback: Bool) -> String { "\(credentials?.server ?? "")|\(credentials?.username ?? "")|\(text(song.raw["source"]))|\(song.key)|\(quality)|\(allowFallback)" }
    @discardableResult func cover(_ song: Song, completion: @escaping (Result<String, Error>) -> Void) -> Cancellable? {
        let source=text(song.raw["source"])
        guard ["kw","kg","tx","wy","mg"].contains(source),song.raw["offlineId"] == nil,
              song.raw["deviceKey"] == nil,song.raw["openlist"] == nil,!bool(song.raw["isLocal"]) else { return nil }
        return LocalEngine.shared.call("api",["path":"/api/music/pic?source="+source,"body":["songInfo":ArtworkAddress.providerSong(song)]]) { [weak self] result in
            do {
                let response=try result.get() as? Object ?? [:]
                let address=ArtworkAddress.normalize(text(response["url"]),base:self?.base)
                guard !address.isEmpty else { throw ClientError("音源没有返回封面地址") }
                completion(.success(address))
            } catch { completion(.failure(error)) }
        }
    }
    private func formatHint(_ url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "flac": return "flac"
        case "mp3": return "mp3"
        case "wav": return "wav"
        case "m4a", "aac", "mp4": return "aac"
        case "ogg", "opus": return "opus"
        default: return nil
        }
    }
    private func resolvedAudio(url: URL, reportedQuality: String, requestedQuality: String, qualityReported: Bool) -> ResolvedAudio {
        let hint = formatHint(url), reported = reportedQuality.lowercased()
        let conflictsWithFLAC = ["flac", "flac24bit"].contains(reported) && hint != nil && hint != "flac"
        let playbackQuality = conflictsWithFLAC ? (hint ?? requestedQuality) : (!reportedQuality.isEmpty ? reportedQuality : (hint ?? requestedQuality))
        let reportedOK = qualityReported && !conflictsWithFLAC
        if conflictsWithFLAC {
            RuntimeTrace.record("audio.quality-format-conflict", ["sourceReported": reportedQuality, "urlFormat": hint ?? "unknown"])
        } else if !reportedOK {
            RuntimeTrace.record("audio.quality-unverified", ["source": "unreported", "requested": requestedQuality, "urlFormat": hint ?? "unknown"])
        }
        return ResolvedAudio(url: url, playbackQuality: playbackQuality, qualityReported: reportedOK)
    }
    var prepareDevice: ((Song, @escaping (Result<URL, Error>) -> Void) -> Cancellable?)?
    func importKey(_ key: String) -> String {
        "lx.import." + (credentials?.server ?? "") + "." + (credentials?.username ?? "") + "." + key
    }
    func importedURL(_ key: String) -> URL? {
        guard !key.isEmpty, let stored = UserDefaults.standard.string(forKey:importKey(key)),
              let url = URL(string:stored), url.isFileURL, let directory = try? WebController.importDirectory(),
              url.standardizedFileURL.deletingLastPathComponent().path == directory.standardizedFileURL.path,
              FileManager.default.fileExists(atPath:url.path) else { return nil }
        return url
    }
    @discardableResult func resolve(_ song: Song, quality: String, allowFallback: Bool, completion: @escaping (Result<ResolvedAudio, Error>) -> Void) -> Cancellable? {
        if let local = MusicLibrary.shared.localURL(song) {
            let reported = text(song.raw["quality"]).isEmpty ? local.pathExtension.lowercased() : text(song.raw["quality"])
            completion(.success(ResolvedAudio(url: local, playbackQuality: reported.isEmpty ? "unknown" : reported, qualityReported: !reported.isEmpty)))
            return nil
        }
        let key = cacheKey(song, quality, allowFallback)
        if let cached = sourceCache[key], Date().timeIntervalSince(cached.1) < 180 { completion(.success(cached.0)); return nil }
        if song.raw["openlist"] is Object {
            return request("/api/openlist/play", method: "POST", body: song.raw["openlist"] as? Object) { [weak self] result in
                do {
                    let value = try result.get()
                    guard let self = self, let base = self.base else { throw ClientError("服务器地址无效") }
                    var components = URLComponents(url: try MediaAddress.direct(text(value["url"]), base: base), resolvingAgainstBaseURL: false)!
                    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: self.credentials?.token)]
                    guard let url = components.url else { throw ClientError("网盘播放地址无效") }
                    let reported = text(song.raw["quality"])
                    completion(.success(self.resolvedAudio(url: url, reportedQuality: reported, requestedQuality: quality, qualityReported: !reported.isEmpty)))
                } catch { completion(.failure(error)) }
            }
        }
        if let key = song.raw["deviceKey"] as? String, !key.isEmpty {
            let ready: (Result<URL, Error>) -> Void = { result in
                completion(result.map { self.resolvedAudio(url:$0, reportedQuality:text(song.raw["quality"]), requestedQuality:quality, qualityReported:true) })
            }
            if let url = importedURL(key) { ready(.success(url)); return nil }
            if let prepare = prepareDevice { return prepare(song, ready) }
            ready(.failure(ClientError("请打开手机 App 准备这首设备音乐"))); return nil
        }
        if let direct = song.raw["url"] as? String, !direct.isEmpty, bool(song.raw["isLocal"]) || song.raw["openlist"] != nil || song.raw["deviceKey"] != nil {
            let base = base ?? URL(string: "https://lx-device.invalid/")!
            do {
                let address = try MediaAddress.direct(direct, base: base)
                if address.isFileURL {
                    let folder = try WebController.importDirectory().standardizedFileURL.path + "/"
                    let downloads = try MusicLibrary.shared.directory().standardizedFileURL.path + "/"
                    guard address.standardizedFileURL.path.hasPrefix(folder) || address.standardizedFileURL.path.hasPrefix(downloads) else { throw ClientError("设备文件不在 App 音乐库中") }
                }
                let reported = text(song.raw["quality"])
                completion(.success(resolvedAudio(url: address, reportedQuality: reported, requestedQuality: quality, qualityReported: !reported.isEmpty)))
            } catch { completion(.failure(error)) }
            return nil
        }
        let revision = sessionRevision
        return LocalEngine.shared.call("resolve", ["song": song.raw, "quality": quality, "allowFallback": allowFallback]) { [weak self] result in
            guard let self = self, self.sessionRevision == revision else { completion(.failure(URLError(.cancelled))); return }
            do {
                guard let value = try result.get() as? Object else { throw ClientError("音源没有返回播放地址") }
                let base = self.base ?? URL(string: "https://lx-device.invalid/")!
                guard !text(value["url"]).isEmpty else { throw ClientError("音源没有返回播放地址") }
                let url = try MediaAddress.direct(text(value["url"]), base: base)
                let reported = text(value["type"]).isEmpty ? text(value["quality"]) : text(value["type"])
                let qualityReported = bool(value["qualityReported"], !reported.isEmpty)
                let media = self.resolvedAudio(url: url, reportedQuality: reported, requestedQuality: quality, qualityReported: qualityReported)
                if self.sourceCache.count > 24 { self.sourceCache.removeAll() }
                self.sourceCache[key] = (media, Date())
                completion(.success(media))
            } catch {
                let useServer = !UserDefaults.standard.bool(forKey: "lx.disableLegacySourceFallback")
                if useServer, self.credentials != nil, (error as? URLError)?.code != .cancelled {
                    self.resolveOnServer(song, quality: quality, allowFallback: allowFallback, completion: completion)
                } else if useServer, self.credentials == nil, error.localizedDescription.hasPrefix("请在") {
                    completion(.failure(ClientError("请登录同步账号使用服务器音源，或在「音源管理」导入本机音源")))
                } else {
                    completion(.failure(error))
                }
            }
        }
    }
    func resolveOnServer(_ song: Song, quality: String, allowFallback: Bool, completion: @escaping (Result<ResolvedAudio, Error>) -> Void) {
        request("/api/music/url", method: "POST", body: ["songInfo": song.raw, "quality": quality, "allowQualityFallback": allowFallback, "enableAutoSwitchApiSource": true]) { [weak self] result in
            do {
                let value = try result.get()
                guard let self = self, let base = self.base, !text(value["url"]).isEmpty else { throw ClientError("音源没有返回播放地址") }
                let url = try MediaAddress.direct(text(value["url"]), base: base)
                let reported = text(value["type"]).isEmpty ? text(value["quality"]) : text(value["type"])
                let media = self.resolvedAudio(url: url, reportedQuality: reported, requestedQuality: quality, qualityReported: bool(value["qualityReported"], !reported.isEmpty))
                completion(.success(media))
            } catch { completion(.failure(error)) }
        }
    }
}
