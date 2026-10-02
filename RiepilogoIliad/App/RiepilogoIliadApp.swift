import SwiftUI

@main
struct RiepilogoIliadApp: App {
    var body: some Scene {
        MenuBarExtra {
            Text("Riepilogo Iliad")
                .padding()
        } label: {
            Image(systemName: "antenna.radiowaves.left.and.right")
        }
    }
}
