import SwiftUI

@main
struct K7BridgeApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in
                    guard url.scheme?.lowercased() == "k7bridge" else { return }
                    model.pair(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.applicationDidBecomeActive() }
                }
                .alert("K7Bridge", isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )) {
                    Button("Tamam", role: .cancel) {}
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
    }
}
