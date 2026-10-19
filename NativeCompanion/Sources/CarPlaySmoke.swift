#if DEBUG
import CarPlay
import Foundation

enum CarPlaySmoke {
    static var started = false
    final class Host: CarScreenHost {
        var roots: [CPTemplate] = []
        var rejectFirst = false
        var topTemplate: CPTemplate? { roots.last }
        func setRoot(_ template: CPTemplate, completion: @escaping (Bool, Error?) -> Void) {
            roots.append(template)
            if rejectFirst && roots.count == 1 { completion(false, ClientError("Fixture root rejection")) } else { completion(true, nil) }
        }
        func push(_ template: CPTemplate) {}
    }
    static func start() {
        guard !started else { return }; started = true
        let car = CarScene(), host = Host()
        var status = "ready"
        for name in ["templateApplicationScene:didConnectInterfaceController:", "templateApplicationScene:didConnectInterfaceController:toWindow:", "templateApplicationScene:didDisconnectInterfaceController:", "templateApplicationScene:didDisconnectInterfaceController:fromWindow:"] {
            if !car.responds(to: NSSelectorFromString(name)) { status = "failed: missing callback " + name }
        }
        car.connect(host, window: nil, callback: "smoke-audio")
        if let root = host.roots.first as? CPTabBarTemplate {
            if root.templates.count != 3 || !root.templates.allSatisfy({ ($0 as? CPListTemplate)?.sections.isEmpty == false }) { status = "failed: empty root templates" }
        } else { status = "failed: missing tab root" }
        if CarScene.connectedScene !== car || car.host == nil { status = "failed: connection not retained" }
        car.releaseConnection()
        if CarScene.connectedScene != nil || car.host != nil || car.rootTemplate != nil { status = "failed: connection not released" }
        let fallback = Host(); fallback.rejectFirst = true
        car.connect(fallback, window: nil, callback: "smoke-window")
        if fallback.roots.count != 2 || !(fallback.roots.last is CPListTemplate) || text(CarScene.diagnostic["phase"]) != "车机简洁菜单已就绪" { status = "failed: fallback root missing" }
        car.releaseConnection()
        if let root = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) { try? Data(status.utf8).write(to: root.appendingPathComponent("CarPlaySmokeReady"), options: .atomic) }
    }
}
#endif
