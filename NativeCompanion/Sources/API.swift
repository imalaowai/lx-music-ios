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
final class API {
    var credentials: Credentials?
    var sourceCache: [String: (URL, String, Date)] = [:]
    let session: URLSession
    init() {
        credentials = Vault.load()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }
    var base: URL? { credentials?.url }
    func url(_ path: String) -> URL? { guard let base = base else { return nil }; return URL(string: path, relativeTo: base)?.absoluteURL }
    @discardableResult func request(_ path: String, method: String = "GET", body: Object? = nil, completion: @escaping (Result<Object, Error>) -> Void) -> URLSessionDataTask? {
        guard let url = url(path), let identity = credentials else { completion(.failure(ClientError("请先打开手机页面登录音乐账号"))); return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(identity.token, forHTTPHeaderField: "x-user-token")
        request.setValue(identity.username, forHTTPHeaderField: "x-user-name")
        if let body = body { request.httpBody = try? JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let task = session.dataTask(with: request) { data, response, error in
            var result: Result<Object, Error>
            if let error = error { result = .failure(error) }
            else if let data = data, let value = (try? JSONSerialization.jsonObject(with: data)) as? Object {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code), value["success"] == nil || bool(value["success"]) { result = .success(value) }
                else { result = .failure(ClientError(text(value["message"]).isEmpty ? (text(value["error"]).isEmpty ? "请求失败（\(code)）" : text(value["error"])) : text(value["message"]))) }
            } else { result = .failure(ClientError("服务返回了无法读取的数据")) }
            DispatchQueue.main.async { [weak self] in
                guard self?.credentials == identity else { return }
                completion(result)
            }
        }
        task.resume()
        return task
    }
    func cacheKey(_ song: Song, _ quality: String, _ allowFallback: Bool) -> String { "\(credentials?.server ?? "")|\(credentials?.username ?? "")|\(text(song.raw["source"]))|\(song.key)|\(quality)|\(allowFallback)" }
    func resolve(_ song: Song, quality: String, allowFallback: Bool, completion: @escaping (Result<(URL, String), Error>) -> Void) -> URLSessionDataTask? {
        let key = cacheKey(song, quality, allowFallback)
        if let cached = sourceCache[key], Date().timeIntervalSince(cached.2) < 180 { completion(.success((cached.0, cached.1))); return nil }
        if song.raw["openlist"] is Object {
            return request("/api/openlist/play", method: "POST", body: song.raw["openlist"] as? Object) { [weak self] result in
                do {
                    let value = try result.get()
                    guard let self = self, let base = self.base else { throw ClientError("服务器地址无效") }
                    var components = URLComponents(url: try MediaAddress.direct(text(value["url"]), base: base), resolvingAgainstBaseURL: false)!
                    components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: self.credentials?.token)]
                    guard let url = components.url else { throw ClientError("网盘播放地址无效") }
                    completion(.success((url, text(song.raw["quality"]))))
                } catch { completion(.failure(error)) }
            }
        }
        if song.raw["deviceKey"] != nil { completion(.failure(ClientError("请先在手机页面中准备设备音乐，再锁屏或连接车机"))); return nil }
        if let direct = song.raw["url"] as? String, !direct.isEmpty, bool(song.raw["isLocal"]) || song.raw["openlist"] != nil || song.raw["deviceKey"] != nil {
            guard let base = base else { completion(.failure(ClientError("服务器地址无效"))); return nil }
            do {
                let address = try MediaAddress.direct(direct, base: base)
                if address.isFileURL {
                    let folder = try WebController.importDirectory().standardizedFileURL.path + "/"
                    guard address.standardizedFileURL.path.hasPrefix(folder) else { throw ClientError("设备文件不在 App 导入目录中") }
                }
                completion(.success((address, text(song.raw["quality"]))))
            } catch { completion(.failure(error)) }
            return nil
        }
        return request("/api/music/url", method: "POST", body: ["songInfo": song.raw, "quality": quality, "allowQualityFallback": allowFallback, "enableAutoSwitchApiSource": true]) { [weak self] result in
            do {
                let value = try result.get()
                guard let base = self?.base, !text(value["url"]).isEmpty else { throw ClientError("音源没有返回播放地址") }
                let url = try MediaAddress.direct(text(value["url"]), base: base), actual = text(value["type"]).isEmpty ? quality : text(value["type"])
                if (self?.sourceCache.count ?? 0) > 24 { self?.sourceCache.removeAll() }
                self?.sourceCache[key] = (url, actual, Date())
                completion(.success((url, actual)))
            } catch { completion(.failure(error)) }
        }
    }
}
