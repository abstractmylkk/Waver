import SwiftUI
import WaverUI

struct ContentView: View {
    @EnvironmentObject private var engine: MeterEngine
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some View {
        MeterDashboard()
            .environmentObject(engine.model)
            .navigationTitle("Waver")
            .navigationSubtitle(engine.selected.displayName)
            .toolbar { toolbar }
            .background(WindowAccessor { window in
                window.level = alwaysOnTop ? .floating : .normal
                window.backgroundColor = NSColor(Theme.background)
            }.id(alwaysOnTop))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                sourceButton(.systemAudio)
                if !engine.applicationSources.isEmpty {
                    Section("Applications") {
                        ForEach(engine.applicationSources) { sourceButton($0) }
                    }
                }
                if !engine.inputSources.isEmpty {
                    Section("Input Devices") {
                        ForEach(engine.inputSources) { sourceButton($0) }
                    }
                }
                Divider()
                Button("Refresh Sources") { engine.refreshSources() }
            } label: {
                Label(engine.selected.displayName, systemImage: engine.selected.symbol)
            }
            .help("Audio source")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            TimeWindowPicker().environmentObject(engine.model)
            TargetMenu().environmentObject(engine.model)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            FreezeButton(showsTitle: false)
                .environmentObject(engine.model)
                .keyboardShortcut(.space, modifiers: [])
            LayoutButtons().environmentObject(engine.model)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                engine.model.resetStatistics()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .help("Reset integrated, LRA and peaks (⌘R)")

            Button {
                alwaysOnTop.toggle()
            } label: {
                Label("Keep on Top", systemImage: alwaysOnTop ? "pin.fill" : "pin")
            }
            .help("Keep Waver above other windows")

            Button {
                engine.toggleRunning()
            } label: {
                Label(engine.isRunning ? "Pause" : "Start", systemImage: engine.isRunning ? "pause.fill" : "play.fill")
            }
            .help(engine.isRunning ? "Pause metering" : "Start metering")
        }
    }

    private func sourceButton(_ source: AudioSource) -> some View {
        Button {
            engine.select(source)
        } label: {
            if source == engine.selected {
                Label(source.displayName, systemImage: "checkmark")
            } else {
                Label(source.displayName, systemImage: source.symbol)
            }
        }
    }
}

/// Gives access to the hosting NSWindow (for "keep on top").
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let w = view.window { configure(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { configure(w) } }
    }
}
