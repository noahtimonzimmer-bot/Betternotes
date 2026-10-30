import SwiftUI

@main
struct BetternotesApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}
