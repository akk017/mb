import MiniBrainUI
import SwiftUI

@main
struct MiniBrainApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var controller

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(controller: controller)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}
