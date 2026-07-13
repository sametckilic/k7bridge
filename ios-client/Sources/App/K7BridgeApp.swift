import SwiftUI

@main
struct K7BridgeApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(model).alert("K7Bridge", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("Tamam", role: .cancel) {} } message: { Text(model.errorMessage ?? "") } }
    }
}

