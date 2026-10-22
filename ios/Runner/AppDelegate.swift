import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var scannerBridge: RoomPlanBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      scannerBridge = RoomPlanBridge(controller: controller)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
