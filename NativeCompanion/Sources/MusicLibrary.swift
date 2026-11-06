import Foundation
import AVFoundation
import UIKit
import WebKit
import ImageIO

final class MusicLibrary: NSObject, URLSessionDownloadDelegate, WKURLSchemeHandler {
    static let shared = MusicLibrary()
    var records: [Object] = []
    var onChange: ((Object) -> Void)?
    var backgroundCompletion: (() -> Void)?
    private var progressAt: [String: Date] = [:]
    private var resolving = Set<String>()
    private var finalizing = Set<String>()
    private(set) var playableRevision = 0
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "net.minyue.lxcompanion.downloads")
        config.httpMaximumConnectionsPerHost = 2; config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        queue.name = "net.minyue.lxcompanion.downloads"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()
    override init() {
        super.init()
        if let file = try? directory().appendingPathComponent("index.json"), let data = try? Data(contentsOf: file), let saved = (try? JSONSerialization.jsonObject(with: data)) as? [Object] { records = saved }
    }
    func directory() throws -> URL {
        let root = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try DownloadedAudioFile.allowBackgroundAccess(root); return root
    }
    func folder(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw ClientError("音乐记录无效") }
        let root = try directory().appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); try DownloadedAudioFile.allowBackgroundAccess(root); return root
    }
    func persist() {
        guard let root = try? directory(), let data = try? JSONSerialization.data(withJSONObject: records) else { return }
        try? data.write(to: root.appendingPathComponent("index.json"), options: .atomic)
    }
    func changed(_ id: String) {
        if let row = records.first(where: {text($0["id"]) == id}) { onChange?(row) }
        NotificationCenter.default.post(name: .lxDownloads, object: self)
    }
    func patch(_ id: String, _ values: Object, save: Bool = true) {
        guard let index = records.firstIndex(where: {text($0["id"]) == id}) else { return }
        let finished = text(records[index]["status"]) == "finished"
        records[index].merge(values) { _, value in value }
        if finished != (text(records[index]["status"]) == "finished") { playableRevision += 1 }
        if save { persist() }
        changed(id)
    }
    func localURL(_ song: Song) -> URL? {
        let offlineID = text(song.raw["offlineId"])
        let row = records.first { row in
            guard text(row["status"]) == "finished", let raw = row["song"] as? Object else { return false }
            if !offlineID.isEmpty { return offlineID == text(row["id"]) }
            return Song(raw: raw).key == song.key && text(raw["source"]) == text(song.raw["source"])
        }
        guard let row = row, let root = try? folder(text(row["id"])) else { return nil }
        let filename = text(row["filename"])
        guard !filename.isEmpty, (filename as NSString).lastPathComponent == filename else { return nil }
        let url = root.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func coverURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil, let root = try? folder(id) else { return nil }
        let url = root.appendingPathComponent("封面.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func songs() -> [Object] {
        records.map { row in
            var result = row, raw = row["song"] as? Object ?? [:]
            raw["offlineId"] = row["id"]
            // Never send web IndexedDB device keys or expired sandbox URLs back to JS.
            raw.removeValue(forKey: "deviceKey"); raw.removeValue(forKey: "url")
            raw["quality"] = row["quality"]
            if bool(row["hasCover"]) { raw["img"] = "lx-local://cover/" + text(row["id"]) }
            result["song"] = raw; return result
        }
    }
    func assets(_ id: String) throws -> Object {
        guard records.contains(where: {text($0["id"]) == id}) else { throw ClientError("没有找到这首已下载歌曲") }
        let root = try folder(id)
        if let data = try? Data(contentsOf: root.appendingPathComponent("lyrics.json")), let value = (try? JSONSerialization.jsonObject(with: data)) as? Object { return value }
        return [:]
    }
    func download(_ song: Song, quality: String, api: API, parts: [String] = ["song", "lyrics", "cover"], completion: @escaping (Result<Object, Error>) -> Void) {
        if let existing = records.first(where: { row in guard let raw = row["song"] as? Object else { return false }; return Song(raw: raw).key == song.key && text(raw["source"]) == text(song.raw["source"]) && text(row["quality"]) == quality && Set(row["parts"] as? [String] ?? ["song", "lyrics", "cover"]) == Set(parts) && ["finished", "resolving", "downloading"].contains(text(row["status"])) }) { completion(.success(existing)); return }
        let id = UUID().uuidString
        records.insert(["id": id, "song": song.raw, "status": "resolving", "quality": quality, "progress": 0, "parts": parts, "createdAt": Date().timeIntervalSince1970 * 1000], at: 0); persist(); changed(id)
        if !parts.contains("song") {
            patch(id, ["status": "assets", "quality": quality]); cacheAssets(id, song: song)
            completion(.success(["id": id])); return
        }
        resolving.insert(id)
        api.resolve(song, quality: quality, allowFallback: true) { [weak self] result in
            self?.resolving.remove(id)
            guard let self = self, self.records.contains(where: {text($0["id"]) == id && text($0["status"]) == "resolving"}) else { completion(.failure(ClientError("下载已取消"))); return }
            do {
                let media = try result.get(), url = media.url, actual = media.playbackQuality
                guard ["http", "https"].contains(url.scheme ?? "") else { throw ClientError("这首歌曲已在设备中，无需再次下载") }
                self.patch(id, ["status": "downloading", "quality": actual])
                let task = self.session.downloadTask(with: url); task.taskDescription = id; task.resume()
                self.cacheAssets(id, song: song)
                completion(.success(["id": id]))
            } catch { self.patch(id, ["status": "error", "error": error.localizedDescription]); completion(.failure(error)) }
        }
    }
    func cacheAssets(_ id: String, song: Song) {
        var raw = song.raw
        if let meta = raw["meta"] as? Object { raw = meta.merging(raw) { _, value in value } }
        let source = text(raw["source"]), songmid = text(raw["songmid"]).isEmpty ? text(raw["songId"]) : text(raw["songmid"])
        if !source.isEmpty, source != "local", (records.first {text($0["id"]) == id}?["parts"] as? [String] ?? ["lyrics"]).contains("lyrics") {
            var query = URLComponents(); query.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "songmid", value: songmid)]
            LocalEngine.shared.call("api", ["path": "/api/music/lyric?" + (query.percentEncodedQuery ?? ""), "body": ["songInfo": raw]]) { [weak self] result in
                guard let self = self, self.records.contains(where: {text($0["id"]) == id}), case .success(let value) = result, let lyric = value as? Object else { return }
                self.saveLyrics(lyric, id: id)
            }
        }
        guard (records.first {text($0["id"]) == id}?["parts"] as? [String] ?? ["cover"]).contains("cover") else { return }
        let picture = text(raw["img"]).isEmpty ? text(raw["picUrl"]) : text(raw["img"])
        if picture.isEmpty, !source.isEmpty, source != "local" {
            LocalEngine.shared.call("api", ["path": "/api/music/pic?source=" + source, "body": ["songInfo": raw]]) { [weak self] result in
                guard let self = self, self.records.contains(where: {text($0["id"]) == id}), case .success(let value) = result, let object = value as? Object else { return }
                self.cacheCover(id, from: text(object["url"]))
            }
        } else { cacheCover(id, from: picture) }
    }
    func cacheCover(_ id: String, from picture: String) {
        guard let url = URL(string: picture), ["http", "https"].contains(url.scheme ?? "") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, data.count < 8_000_000 else { return }
            self.saveCover(data, id: id)
        }.resume()
    }
    func saveLyrics(_ value: Object, id: String) {
        let lrc = text(value["lyric"]).isEmpty ? text(value["lrc"]) : text(value["lyric"])
        guard !lrc.isEmpty, lrc.utf8.count < 2_000_000, let root = try? folder(id) else { return }
        var lyric = value; lyric["lyric"] = lrc; lyric["lrc"] = lrc
        if let data = try? JSONSerialization.data(withJSONObject: lyric) { try? data.write(to: root.appendingPathComponent("lyrics.json"), options: .atomic) }
        try? lrc.write(to: root.appendingPathComponent("歌词.lrc"), atomically: true, encoding: .utf8)
        DispatchQueue.main.async { [weak self] in self?.patch(id, ["hasLyric": true]) }
    }
    func saveCover(_ data: Data, id: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary), let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85), let root = try? folder(id) else { return }
        try? jpeg.write(to: root.appendingPathComponent("封面.jpg"), options: .atomic)
        DispatchQueue.main.async { [weak self] in self?.patch(id, ["hasCover": true]) }
    }
    func restoreTasks() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self = self else { return }; let ids = Set(tasks.compactMap(\.taskDescription))
                for row in self.records where ["downloading", "resolving"].contains(text(row["status"])) {
                    let id = text(row["id"])
                    if !ids.contains(id), !self.resolving.contains(id), !self.finalizing.contains(id) {
                        self.patch(id, ["status":"error", "error":"下载已中断，可重新下载"])
                    }
                }
            }
        }
    }
    func cancel(_ id: String) {
        session.getAllTasks { tasks in for task in tasks where task.taskDescription == id { task.cancel() } }
        patch(id, ["status": "error", "error": "已取消，可重新下载"])
    }
    func remove(_ id: String) throws {
        guard let row = records.first(where: {text($0["id"]) == id}) else { return }
        if text(row["status"]) == "downloading" { cancel(id) }
        try FileManager.default.removeItem(at: folder(id)); records.removeAll { text($0["id"]) == id }
        if text(row["status"]) == "finished" { playableRevision += 1 }
        persist(); onChange?(["id":id, "deleted":true])
        NotificationCenter.default.post(name:.lxDownloads, object:self)
    }
    func shareFiles(_ id: String) throws -> [URL] {
        guard let row = records.first(where: {text($0["id"]) == id}) else { throw ClientError("没有找到这条下载记录") }
        let root = try folder(id)
        var files = [root.appendingPathComponent("封面.jpg"), root.appendingPathComponent("歌词.lrc")]
        if let raw = row["song"] as? Object, let audio = localURL(Song(raw: raw.merging(["offlineId":id]) {_,new in new})) { files.insert(audio, at: 0) }
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { throw ClientError("文件尚未保存完成，请稍后重试") }; return existing
    }
    func importFiles(_ urls: [URL], completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }; var added: [Object] = []
            do {
                for url in urls where ["mp3", "m4a", "flac", "aac", "wav", "aiff", "alac", "ogg", "opus"].contains(url.pathExtension.lowercased()) {
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let id = UUID().uuidString, root = try self.folder(id), name = url.lastPathComponent
                    try FileManager.default.copyItem(at: url, to: root.appendingPathComponent(name))
                    let asset = AVURLAsset(url: root.appendingPathComponent(name)), metadata = asset.commonMetadata
                    let title = metadata.first(where: {$0.commonKey == .commonKeyTitle})?.stringValue ?? url.deletingPathExtension().lastPathComponent
                    let artist = metadata.first(where: {$0.commonKey == .commonKeyArtist})?.stringValue ?? "设备音乐"
                    var hasCover = false, hasLyric = false
                    if let cover = metadata.first(where: {$0.commonKey == .commonKeyArtwork})?.dataValue { self.saveCover(cover, id: id); hasCover = true }
                    if let lyric = asset.metadata.first(where: {$0.identifier?.rawValue.contains("USLT") == true || $0.identifier?.rawValue.lowercased().contains("lyrics") == true})?.stringValue { self.saveLyrics(["lyric": lyric], id: id); hasLyric = true }
                    let stem = url.deletingPathExtension().lastPathComponent
                    for sidecar in urls where sidecar.deletingPathExtension().lastPathComponent == stem {
                        let granted = sidecar.startAccessingSecurityScopedResource(); defer { if granted { sidecar.stopAccessingSecurityScopedResource() } }
                        if sidecar.pathExtension.lowercased() == "lrc", let lyric = try? String(contentsOf: sidecar) { self.saveLyrics(["lyric": lyric], id: id); hasLyric = true }
                        else if ["jpg", "jpeg", "png", "webp"].contains(sidecar.pathExtension.lowercased()), let data = try? Data(contentsOf: sidecar) { self.saveCover(data, id: id); hasCover = true }
                    }
                    let song: Object = ["id": "device-" + id, "name": title, "singer": artist, "source": "local", "isLocal": true, "offlineId": id, "url": root.appendingPathComponent(name).absoluteString]
                    added.append(["id": id, "song": song, "filename": name, "status": "finished", "quality": url.pathExtension.lowercased(), "progress": 100, "hasCover": hasCover, "hasLyric": hasLyric, "bytes": (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.size]) ?? 0, "createdAt": Date().timeIntervalSince1970 * 1000])
                }
                DispatchQueue.main.async { self.records.insert(contentsOf: added, at: 0); self.playableRevision += 1; self.persist(); for row in added { self.changed(text(row["id"])) }; completion(.success(added.count)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, Date().timeIntervalSince(progressAt[id] ?? .distantPast) > 0.5 else { return }
        progressAt[id] = Date()
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100 : 0
        DispatchQueue.main.async {
            guard self.isDownloading(id) else { return }
            self.patch(id, ["bytes":totalBytesWritten, "progress":progress], save:false)
        }
    }
    private func isDownloading(_ id: String) -> Bool {
        records.contains { text($0["id"]) == id && text($0["status"]) == "downloading" }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let song: Object? = DispatchQueue.main.sync {
            guard let row = self.records.first(where:{ text($0["id"]) == id && text($0["status"]) == "downloading" }) else { return nil }
            self.finalizing.insert(id)
            return row["song"] as? Object ?? [:]
        }
        guard let song = song else { return }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory:true)
        let result = Result { () -> (URL, NSNumber) in
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw ClientError("下载失败，请重新解析音源")
            }
            let file = try DownloadedAudioFile.persist(source:location, directory:staging, name:text(song["name"]))
            let bytes = (try FileManager.default.attributesOfItem(atPath:file.path)[.size]) as? NSNumber ?? 0
            return (file, bytes)
        }
        DispatchQueue.main.async {
            defer {
                self.finalizing.remove(id)
                DispatchQueue.global(qos:.utility).async { try? FileManager.default.removeItem(at:staging) }
            }
            guard self.isDownloading(id) else { return }
            do {
                let (file, bytes) = try result.get()
                let destination = try self.folder(id).appendingPathComponent(file.lastPathComponent)
                if FileManager.default.fileExists(atPath:destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt:file)
                } else { try FileManager.default.moveItem(at:file, to:destination) }
                self.patch(id, ["filename":file.lastPathComponent, "status":"finished", "progress":100, "bytes":bytes, "error":""])
            } catch { self.patch(id, ["status":"error", "error":error.localizedDescription]) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        progressAt.removeValue(forKey:id)
        guard let error = error else { return }
        DispatchQueue.main.async {
            if self.isDownloading(id) { self.patch(id, ["status":"error", "error":error.localizedDescription]) }
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { DispatchQueue.main.async { self.backgroundCompletion?(); self.backgroundCompletion = nil } }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "cover", UUID(uuidString: url.lastPathComponent) != nil, let root = try? folder(url.lastPathComponent), let data = try? Data(contentsOf: root.appendingPathComponent("封面.jpg")) else { urlSchemeTask.didFailWithError(ClientError("封面不存在")); return }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/jpeg", expectedContentLength: data.count, textEncodingName: nil)); urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
extension Notification.Name { static let lxDownloads = Notification.Name("LXNativeDownloads") }
