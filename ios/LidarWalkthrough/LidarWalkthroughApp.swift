import SwiftUI

@main
struct LidarWalkthroughApp: App {
  @StateObject private var store = PropertyStore()

  var body: some Scene {
    WindowGroup {
      PropertyListScreen().environmentObject(store)
    }
  }
}
