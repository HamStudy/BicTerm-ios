import SwiftUI

@main
struct BicTermApp: App {
    var body: some Scene {
        WindowGroup("BicTerm") {
            ConnectionListView()
                .terminalStyle()
        }

        WindowGroup("Terminal", id: "terminal", for: SessionID.self) { _ in
            TerminalPlaceholderView(connectionName: "Terminal Session")
                .terminalStyle()
        }
    }
}
