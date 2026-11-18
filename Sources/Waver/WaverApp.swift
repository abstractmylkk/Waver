import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = MeterEngine()

    init() {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            let args = CommandLine.arguments
            var size = CGSize(width: 1120, height: 620)
            if i + 2 < args.count {
                let wh = args[i + 2].split(separator: "x").compactMap { Double($0) }
                if wh.count == 2 { size = CGSize(width: wh[0], height: wh[1]) }
            }
            SnapshotRenderer.run(output: args[i + 1], size: size, frozen: args.contains("--frozen"))
            exit(0)
        }
    }

    var body: some Scene {
        Window("Waver", id: "main") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 480, minHeight: 300)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1120, height: 660)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Meter") {
                Button("Reset Statistics") { engine.model.resetStatistics() }
                    .keyboardShortcut("r", modifiers: .command)
                Button(engine.isRunning ? "Pause Metering" : "Start Metering") { engine.toggleRunning() }
                    .keyboardShortcut("p", modifiers: .command)
                Button(engine.model.isFrozen ? "Resume Waveform" : "Freeze Waveform") { engine.model.toggleFreeze() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Toggle("Logarithmic Waveform", isOn: Binding(
                    get: { engine.model.settings.logScale },
                    set: { engine.model.settings.logScale = $0 }))
                    .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
