import UIKit

// A real WebKit launch of the same Swift root/resources used in the integrated
// library. This checks phone embedding, not physical CarPlay or reference audio.
@main final class OwnHostApp:UIResponder,UIApplicationDelegate {
    func application(_ application:UIApplication,didFinishLaunchingWithOptions options:[UIApplication.LaunchOptionsKey:Any]?)->Bool { OwnIntegration.activate();return true }
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions)->UISceneConfiguration {
        let config=UISceneConfiguration(name:"Phone",sessionRole:session.role);config.delegateClass=OwnHostScene.self;return config
    }
}
final class OwnHostScene:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene=scene as? UIWindowScene else { return }
        let window=UIWindow(windowScene:scene),parent=UIViewController()
        window.rootViewController=parent;window.makeKeyAndVisible();self.window=window
        guard let root=LXOwnMakeRoot() else { fatalError("ObjC bridge cannot find owned root view") }
        root.frame=parent.view.bounds;root.autoresizingMask=[.flexibleWidth,.flexibleHeight];parent.view.addSubview(root)
    }
}
