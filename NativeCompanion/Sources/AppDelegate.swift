import UIKit
import CarPlay

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { _ = Player.shared; return true }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) { MusicLibrary.shared.backgroundCompletion = completionHandler; MusicLibrary.shared.restoreTasks() }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let car = connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication"
        let config = UISceneConfiguration(name: car ? "CarPlay" : "Phone", sessionRole: connectingSceneSession.role)
        config.delegateClass = car ? CarScene.self : PhoneScene.self
        if car { config.sceneClass = CPTemplateApplicationScene.self }
        return config
    }
}
final class PhoneScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene); window.rootViewController = UINavigationController(rootViewController: WebController()); window.makeKeyAndVisible(); self.window = window
    }
    func sceneDidBecomeActive(_ scene: UIScene) { Player.shared.publish(); Player.shared.room.refresh() }
}
