import Foundation

@main struct EngineNativeTests {
    static func main() {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("generated/LocalEngine.js")
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("LXEngineTest-" + UUID().uuidString)
        let engine = LocalEngine(bundleURL: source, storageURL: store)
        let endpoint = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:1/"
        let script = """
        lx.on('request', async ({info})=>{
          if(lx.utils.crypto.md5('hello')!=='5d41402abc4b2a76b9719d911017c592')throw Error('Crypto mismatch');
          const bytes=lx.utils.crypto.randomBytes(16);if(bytes.length!==16)throw Error('Random bridge failed');
          await new Promise((resolve,reject)=>lx.request('\(endpoint)/form',{method:'POST',form:{cipher:'a+b/c== 汉字 &value=1%#?', 'a+b':'x+y',empty:''}},(error,response,body)=>{
            if(error)return reject(error);
            if(response.statusCode!==200||body.valid!==true)return reject(Error('Form ciphertext changed in native HTTP bridge'));
            resolve();
          }));
          return await new Promise((resolve,reject)=>lx.request('\(endpoint)',{method:'POST',body:{song:info.musicInfo.songmid}},(error,response,body)=>error?reject(error):resolve(body.url)));
        });
        lx.send('inited',{sources:{kw:{qualitys:['128k'],actions:['musicUrl']}}});
        """
        var complete = false, failure: Error?
        engine.call("import", ["id": UUID().uuidString, "name": "Native fixture", "script": script]) { result in
            do { _ = try result.get() } catch { failure = error; complete = true; return }
            engine.call("resolve", ["song": ["songmid": "123", "source": "kw", "name": "Native fixture"], "quality": "128k"]) { result in
                do { let value = try result.get() as? Object; if text(value?["url"]) != "https://audio.invalid/native.mp3" { throw ClientError("Unexpected native source URL") } }
                catch { failure = error }
                complete = true
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while !complete && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        try? FileManager.default.removeItem(at: store)
        if let failure = failure { fatalError(failure.localizedDescription) }
        guard complete else { fatalError("Native JavaScriptCore timed out") }
        print("Native JavaScriptCore: source import, crypto, strict form ciphertext and URLSession callback passed.")
    }
}
