import SwiftUI
import TelegramKit

@main
struct TelegramViewerApp: App {
    var body: some Scene {
        WindowGroup {
            TelegramViewerRoot()
        }
        .defaultSize(width: 1100, height: 720)
    }
}
