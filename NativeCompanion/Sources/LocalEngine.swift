import Foundation
import JavaScriptCore
import Security
import CoreFoundation

protocol Cancellable { func cancel() }
extension URLSessionTask: Cancellable {}
final class LocalRequest: Cancellable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Source scripts and provider SDK run on a separate serial queue, never the UI thread.
/// This context has network and timers, but no filesystem, account token or UIKit access.
final class LocalEngine {
    static let shared = LocalEngine()
    let queue = DispatchQueue(label: "net.minyue.lx.sources", qos: .userInitiated)
    let session: URLSession
    let bundleURL: URL?
    let storageURL: URL?
    var context: JSContext?
    var ready = false
    var sequence = 0
    var callbacks: [Int: (Result<Any, Error>) -> Void] = [:]
    var tasks: [Int: URLSessionDataTask] = [:]
    var waiting: [() -> Void] = []
    var records: [Object] = []
    init(bundleURL: URL? = nil, storageURL: URL? = nil) {
        self.bundleURL = bundleURL; self.storageURL = storageURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config)
    }
    func directory() throws -> URL {
        let root = try storageURL ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("LocalSources", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
    }
    func persist() {
        guard let root = try? directory(), let data = try? JSONSerialization.data(withJSONObject: records) else { return }
        try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }
    func bootstrap() {
        guard context == nil else { return }
        let js = JSContext()!; context = js
        js.exceptionHandler = { _, _ in /* Per-operation failures return through __nativeComplete. */ }
        let random: @convention(block) (Int) -> String = { count in
            guard count >= 0, count <= 65536 else { return "" }
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { return "" }
            return Data(bytes).base64EncodedString()
        }
        let timer: @convention(block) (Int, Double) -> Void = { [weak self] id, delay in
            guard let self = self else { return }
            self.queue.asyncAfter(deadline: .now() + max(0, min(delay, 86_400_000)) / 1000) { [weak self] in self?.context?.objectForKeyedSubscript("__runTimer")?.call(withArguments: [id]) }
        }
        let parseURL: @convention(block) (String, String) -> String = { input, base in
            guard let url = URL(string: input, relativeTo: URL(string: base))?.absoluteURL, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "{}" }
            let host = c.host ?? "", port = c.port.map { ":\($0)" } ?? "", scheme = c.scheme ?? "https"
            let value: Object = ["protocol": scheme + ":", "hostname": host, "host": host + port, "port": c.port.map(String.init) ?? "", "origin": scheme + "://" + host + port, "pathname": c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath, "search": c.percentEncodedQuery.map { "?" + $0 } ?? "", "hash": c.percentEncodedFragment.map { "#" + $0 } ?? ""]
            return String(data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data(), encoding: .utf8) ?? "{}"
        }
        let request: @convention(block) (Int, String) -> Void = { [weak self] id, json in self?.http(id, json: json) }
        let cancel: @convention(block) (Int) -> Void = { [weak self] id in self?.tasks.removeValue(forKey: id)?.cancel() }
        let complete: @convention(block) (Int, String, String) -> Void = { [weak self] id, json, error in
            guard let self = self, let callback = self.callbacks.removeValue(forKey: id) else { return }
            if !error.isEmpty { callback(.failure(ClientError(error))); return }
            guard let data = json.data(using: .utf8), data.count <= 20 * 1024 * 1024, let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { callback(.failure(ClientError("本地音源返回了无效数据"))); return }
            callback(.success(value))
        }
        js.setObject(random, forKeyedSubscript: "__nativeRandom" as NSString)
        js.setObject(timer, forKeyedSubscript: "__nativeTimer" as NSString)
        js.setObject(parseURL, forKeyedSubscript: "__nativeURL" as NSString)
        js.setObject(request, forKeyedSubscript: "__nativeHTTP" as NSString)
        js.setObject(cancel, forKeyedSubscript: "__nativeCancel" as NSString)
        js.setObject(complete, forKeyedSubscript: "__nativeComplete" as NSString)
        js.evaluateScript("var console={log:function(){},warn:function(){},error:function(){}};")
        guard let file = bundleURL ?? Bundle.main.url(forResource: "LocalEngine", withExtension: "js"), let script = try? String(contentsOf: file) else { finishBootstrap(); return }
        js.evaluateScript(script)
        if let root = try? directory(), let data = try? Data(contentsOf: root.appendingPathComponent("index.json")), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [Object] { records = Array(saved.prefix(20)) }
        var remaining = records.count
        if remaining == 0 { finishBootstrap(); return }
        for record in records {
            guard let root = try? directory(), let id = record["id"] as? String, UUID(uuidString: id) != nil, let code = try? String(contentsOf: root.appendingPathComponent(id + ".js")) else { remaining -= 1; if remaining == 0 { finishBootstrap() }; continue }
            execute("import", ["id": id, "name": text(record["name"]), "script": code, "enabled": bool(record["enabled"], true)]) { [weak self] _ in remaining -= 1; if remaining == 0 { self?.finishBootstrap() } }
        }
    }
    func finishBootstrap() { ready = true; let calls = waiting; waiting = []; for call in calls { call() } }
    func execute(_ operation: String, _ values: Object, completion: @escaping (Result<Any, Error>) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: values), let payload = String(data: data, encoding: .utf8), let function = context?.objectForKeyedSubscript("__engineRun"), !function.isUndefined else { completion(.failure(ClientError("本地音源引擎未就绪，请重新安装完整 App"))); return }
        sequence += 1; let id = sequence; callbacks[id] = completion
        function.call(withArguments: [id, operation, payload])
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in self?.callbacks.removeValue(forKey: id)?(.failure(ClientError("音源请求超时，请换源或稍后重试"))) }
    }
    @discardableResult func call(_ operation: String, _ values: Object = [:], completion: @escaping (Result<Any, Error>) -> Void) -> Cancellable {
        let token = LocalRequest()
        queue.async { [weak self] in
            guard let self = self else { return }
            let run = {
                self.execute(operation, values) { result in
                    guard !token.isCancelled else { return }
                    if case .success = result {
                        if operation == "import", let id = values["id"] as? String, UUID(uuidString: id) != nil, let code = values["script"] as? String, let root = try? self.directory() {
                            try? code.write(to: root.appendingPathComponent(id + ".js"), atomically: true, encoding: .utf8)
                            self.records.removeAll { text($0["id"]) == id }; self.records.append(["id": id, "name": text(values["name"]), "enabled": true]); self.persist()
                        } else if operation == "remove" || operation == "enable" {
                            let id = text(values["id"])
                            if operation == "remove" { self.records.removeAll { text($0["id"]) == id }; if UUID(uuidString: id) != nil, let root = try? self.directory() { try? FileManager.default.removeItem(at: root.appendingPathComponent(id + ".js")) } }
                            else if let index = self.records.firstIndex(where: {text($0["id"]) == id}) { self.records[index]["enabled"] = bool(values["enabled"]) }
                            self.persist()
                        }
                    }
                    DispatchQueue.main.async { completion(result) }
                }
            }
            self.bootstrap(); if self.ready { run() } else { self.waiting.append(run) }
        }
        return token
    }
    func http(_ id: Int, json: String) {
        guard let data = json.data(using: .utf8), let input = (try? JSONSerialization.jsonObject(with: data)) as? Object, let url = URL(string: text(input["url"])), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { finishHTTP(id, value: nil, error: "音源请求地址无效"); return }
        let options = input["options"] as? Object ?? [:]
        var request = URLRequest(url: url); request.httpMethod = text(options["method"]).isEmpty ? "GET" : text(options["method"]).uppercased()
        request.timeoutInterval = min(45, max(3, number(options["timeout"], 25000) / 1000))
        for (key, value) in options["headers"] as? Object ?? [:] { request.setValue(String(describing: value), forHTTPHeaderField: key) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil { request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_5 like Mac OS X) AppleWebKit/605.1.15 LXMusic/1.2", forHTTPHeaderField: "User-Agent") }
        if let form = options["form"] as? Object {
            var c = URLComponents(); c.queryItems = form.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
            request.httpBody = c.percentEncodedQuery?.data(using: .utf8); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else if let body = options["body"] as? String { request.httpBody = body.data(using: .utf8) }
        else if let body = options["body"] as? Object {
            if let encoded = body["base64"] as? String { request.httpBody = Data(base64Encoded: encoded) }
            else { request.httpBody = try? JSONSerialization.data(withJSONObject: body); if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") } }
        }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            var value: Object?, failure = error?.localizedDescription
            if let data = data, let response = response as? HTTPURLResponse, data.count <= 20 * 1024 * 1024 {
                var headers: Object = [:]; for (key, value) in response.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
                let charset = response.textEncodingName?.lowercased() ?? "utf-8"
                let encoding: String.Encoding = charset.contains("gb") ? String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) : .utf8
                value = ["statusCode": response.statusCode, "headers": headers, "base64": data.base64EncodedString(), "text": String(data: data, encoding: encoding) ?? String(data: data, encoding: .isoLatin1) ?? ""]
            } else if failure == nil { failure = "音源响应过大或无法读取" }
            self.queue.async { self.tasks.removeValue(forKey: id); self.finishHTTP(id, value: value, error: failure) }
        }
        tasks[id] = task; task.resume()
    }
    func finishHTTP(_ id: Int, value: Object?, error: String?) {
        let json = value.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        context?.objectForKeyedSubscript("__nativeReply")?.call(withArguments: [id, json, error ?? ""])
    }
}
