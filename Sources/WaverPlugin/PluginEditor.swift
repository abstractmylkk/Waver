import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView
import CoreAudioKit
import SwiftUI
import WaverUI

/// The class the host instantiates (by name, from kAudioUnitProperty_CocoaUI) to build the editor.
@objc(WaverAUViewFactory)
public final class WaverAUViewFactory: NSObject, AUCocoaUIBase {
    public func interfaceVersion() -> UInt32 { 0 }

    public func uiView(forAudioUnit audioUnit: AudioUnit, with preferredSize: NSSize) -> NSView? {
        var pointer: UnsafeMutableRawPointer?
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        let status = AudioUnitGetProperty(audioUnit, 64000 /* kWaverProperty_Plugin */, kAudioUnitScope_Global, 0, &pointer, &size)
        guard status == noErr, let pointer else { return nil }
        let plugin = Unmanaged<WaverPlugin>.fromOpaque(pointer).takeUnretainedValue()
        return MainActor.assumeIsolated { PluginEditor.makeView(plugin: plugin) }
    }
}

/// Weak link from SwiftUI back to the hosting NSView, so the resize grip can change its frame
/// (hosts resize the plug-in window to follow the view).
final class EditorHandle {
    weak var view: NSView?
}

struct PluginEditor: View {
    let plugin: WaverPlugin
    @ObservedObject var model: MeterModel
    let handle: EditorHandle

    static let minSize = NSSize(width: 480, height: 300)
    static let maxSize = NSSize(width: 2600, height: 1600)

    @MainActor
    static func makeView(plugin: WaverPlugin) -> NSView {
        let model = plugin.makeModel()
        let handle = EditorHandle()
        let host = NSHostingView(rootView: PluginEditor(plugin: plugin, model: model, handle: handle).environmentObject(model))
        host.sizingOptions = []   // the view's size is set by the grip / host, not by SwiftUI
        let size = NSSize(width: min(maxSize.width, max(minSize.width, model.settings.editorWidth)),
                          height: min(maxSize.height, max(minSize.height, model.settings.editorHeight)))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        host.postsFrameChangedNotifications = true
        host.appearance = NSAppearance(named: .darkAqua)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor(Theme.background).cgColor
        handle.view = host
        return host
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                header(compact: false)
                header(compact: true)
            }
            MeterDashboard()
        }
        .frame(minWidth: Self.minSize.width, maxWidth: .infinity, minHeight: Self.minSize.height, maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(handle: handle, model: model, minSize: Self.minSize, maxSize: Self.maxSize)
        }
        .preferredColorScheme(.dark)
        .onReceive(Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()) { _ in
            let detail: String
            switch plugin.transportState {
            case 1: detail = "▶ Playing"
            case 0: detail = "■ Stopped"
            default: detail = ""
            }
            if model.statusDetail != detail { model.statusDetail = detail }
        }
    }

    static var credit: some View {
        (Text("by ").foregroundColor(.white.opacity(0.3))
            + Text("mylkAudio").foregroundColor(.white.opacity(0.55)).fontWeight(.semibold))
            .font(.system(size: 9.5, weight: .medium))
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 1, green: 0.4, blue: 0.3),
                                                             Color(red: 0.98, green: 0.8, blue: 0.3),
                                                             Color(red: 0.33, green: 0.7, blue: 1)],
                                                    startPoint: .leading, endPoint: .trailing))
                if compact {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Waver")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                        Self.credit
                    }
                } else {
                    Text("Waver")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Loudness Meter")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                        Self.credit
                    }
                }
            }
            .fixedSize()
            Spacer(minLength: 8)

            if compact {
                TimeWindowMenu()
            } else {
                TimeWindowPicker().labelsHidden().frame(width: 170)
            }
            TargetMenu().fixedSize()

            Button {
                model.settings.resetOnPlay.toggle()
            } label: {
                Label("Reset on Play", systemImage: model.settings.resetOnPlay ? "checkmark.circle.fill" : "circle")
                    .labelStyle(TitleOrIcon(showsTitle: !compact))
                    .foregroundStyle(model.settings.resetOnPlay ? Theme.accent : Color.white.opacity(0.6))
            }
            .help("Reset on Play: clear integrated loudness, LRA and peaks whenever Live's transport starts")

            Button {
                model.resetStatistics()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .labelStyle(TitleOrIcon(showsTitle: !compact))
            }
            .help("Reset integrated loudness, LRA and peaks")

            FreezeButton(showsTitle: !compact)
                .keyboardShortcut("f", modifiers: [])
            LayoutButtons()
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Theme.background)
    }
}

struct TitleOrIcon: LabelStyle {
    let showsTitle: Bool
    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        } else {
            configuration.icon
        }
    }
}

/// Bottom-right corner handle that resizes the plug-in editor (the host window follows the view).
struct ResizeGrip: View {
    let handle: EditorHandle
    let model: MeterModel
    let minSize: NSSize
    let maxSize: NSSize
    @State private var start: (mouse: NSPoint, size: NSSize)?

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 0..<3 {
                let o = CGFloat(i) * 4 + 3
                p.move(to: CGPoint(x: size.width - o, y: size.height - 2))
                p.addLine(to: CGPoint(x: size.width - 2, y: size.height - o))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 1)
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .padding(2)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard let view = handle.view else { return }
                    // Screen coordinates stay valid while the view (and window) change size under the cursor.
                    let mouse = NSEvent.mouseLocation
                    if start == nil { start = (mouse, view.frame.size) }
                    guard let start else { return }
                    let w = min(maxSize.width, max(minSize.width, start.size.width + (mouse.x - start.mouse.x)))
                    let h = min(maxSize.height, max(minSize.height, start.size.height - (mouse.y - start.mouse.y)))
                    view.setFrameSize(NSSize(width: w.rounded(), height: h.rounded()))
                }
                .onEnded { _ in
                    if let view = handle.view {
                        model.settings.editorWidth = view.frame.width
                        model.settings.editorHeight = view.frame.height
                    }
                    start = nil
                }
        )
        .help("Drag to resize")
    }
}
