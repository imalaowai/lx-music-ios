import Foundation

// Real provider responses through production JavaScriptCore + URLSession. No
// account cookies, sync-server proxy, or fixture URLProtocol is used here.
@main struct LiveCatalogue {
    static func main() {
        let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("generated/LocalEngine.js")
        let store=FileManager.default.temporaryDirectory.appendingPathComponent("LXLiveCatalogue-"+UUID().uuidString)
        let engine=LocalEngine(bundleURL:source,storageURL:store)
        var results:[Object]=[],failure:Error?,finished=false
        let started=Date()
        let paths=["/api/music/songList/list?source=wy&sortId=hot&page=1", "/api/music/songList/detail?source=wy&id=18271967084&page=1", "/api/music/songList/detail?source=wy&id=3778678&page=1"]
        func next(_ index:Int) {
            if index==paths.count {finished=true;return}
            let began=Date()
            engine.call("api",["path":paths[index]]) { result in
                do {
                    guard let value=try result.get() as? Object,let songs=value["list"] as? [Object],!songs.isEmpty else {throw ClientError("Live catalogue returned no rows at step \(index)")}
                    if index>0 && !songs.allSatisfy({!text($0["name"]).isEmpty && $0["songmid"] != nil && text($0["source"])=="wy"}) {throw ClientError("Live playlist returned invalid song metadata")}
                    results.append(["step":index,"rows":songs.count,"total":number(value["total"]),"milliseconds":Int(Date().timeIntervalSince(began)*1000)])
                    next(index+1)
                } catch {failure=error;finished=true}
            }
        }
        next(0)
        while !finished && Date().timeIntervalSince(started)<150 {RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
        try? FileManager.default.removeItem(at:store)
        let report:Object=["nativeJavaScriptCore":true,"realURLSession":true,"fixtureResponses":false,"results":results,"passed":finished && failure==nil && results.count==paths.count,"error":failure?.localizedDescription ?? (finished ? "" : "Live provider timed out")]
        let data=try! JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try! data.write(to:URL(fileURLWithPath:"build/provider-live-checks.json"),options:.atomic)
        print(String(data:data,encoding:.utf8)!)
        guard report["passed"] as? Bool==true else {fatalError("Live native catalogue verification failed")}
    }
}
