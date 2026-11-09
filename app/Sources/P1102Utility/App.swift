import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        PrintOptions.registerDefaults()
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        } else {
            P1102App.main()
        }
    }
}

struct P1102App: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var model = PrinterViewModel()

    var body: some Scene {
        Window("P1102 Printer", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 440, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .printItem) {
                Button("Print Document…") { model.chooseAndPrintDocument() }
                    .keyboardShortcut("p")
                Button("Print Test Page") { model.printTestPage() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
