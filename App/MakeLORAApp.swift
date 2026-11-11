import SwiftUI

@main struct MakeLORAApp: App {
    @StateObject private var store = ProjectStore()
    @StateObject private var generation = GenerationStore()
    @StateObject private var pairing = PairingStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).environmentObject(pairing).environmentObject(generation).preferredColorScheme(.dark) }
    }
}
