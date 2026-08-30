import OatmealCore
import SwiftUI

@main
struct OatmealApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 1_080, height: 720)
    }
}
