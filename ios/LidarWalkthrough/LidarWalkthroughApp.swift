import SwiftUI

@main
struct LidarWalkthroughApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = PropertyStore()

  var body: some Scene {
    WindowGroup {
      PropertyListScreen().environmentObject(store)
    }
  }
}
