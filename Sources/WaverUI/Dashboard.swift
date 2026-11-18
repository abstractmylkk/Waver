import SwiftUI
import WaverCore

/// The complete meter surface (waveform, loudness history, readouts, bars, status bar).
/// Shared by the standalone app and the Audio Unit editor. Needs a `MeterModel` environment object.
/// Adapts to its size: narrow → sidebar collapses into a readout strip; short → loudness graph hides.
public struct MeterDashboard: View {
    @EnvironmentObject private var model: MeterModel

    public init() {}

    static let sidebarMinWidth: CGFloat = 700
    /// Readout panels take ~340 pt; below this the Levels meter would be squashed, so use the top strip instead.
    static let sidebarMinHeight: CGFloat = 520
    static let historyMinHeight: CGFloat = 380
    private static let statusHeight: CGFloat = 28
    private static let compactStripHeight: CGFloat = 52
    private static let minWaveformHeight: CGFloat = 90

    public var body: some View {
        GeometryReader { geo in
            let showSidebar = geo.size.width >= Self.sidebarMinWidth && geo.size.height >= Self.sidebarMinHeight
            let showHistory = settings.showHistory && geo.size.height >= Self.historyMinHeight
            let stripHeight = showSidebar ? 0 : Self.compactStripHeight + 8
            let maxHistory = max(70, geo.size.height - Self.statusHeight - 6 - stripHeight - Self.minWaveformHeight - 12)
            let historyHeight = min(max(70, settings.historyHeight), maxHistory)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        if !showSidebar {
                            Live(fps: 12) { CompactReadouts(frame: $0) }
                                .frame(height: Self.compactStripHeight)
                                .padding(.bottom, 8)
                        }
                        waveformPanel
                        if showHistory {
                            ResizeDivider(height: historyHeight, range: 70...maxHistory) {
                                model.settings.historyHeight = $0
                            }
                            historyPanel
                                .frame(height: historyHeight)
                        }
                    }
                    if showSidebar {
                        sidebar
                            .frame(width: 272)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                Live(fps: 12) { StatusBar(frame: $0) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var settings: MeterSettings { model.settings }

    private var waveformPanel: some View {
        Panel("Waveform", titleAccessory: AnyView(ScalePicker()), accessory: {
            ViewThatFits(in: .horizontal) {
                BandLegend()
                EmptyView()
            }
        }) {
            ZStack {
                WaveformGrid(window: settings.window, logScale: settings.logScale)
                Live { frame in
                    WaveformView(columns: frame.snapshot.columns,
                                 endIndex: frame.snapshot.columnIndex,
                                 head: frame.head,
                                 columnRate: frame.snapshot.columnRate,
                                 window: settings.window,
                                 logScale: settings.logScale)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggleFreeze() }
            .help(model.isFrozen ? "Click to resume live waveform" : "Click to freeze the waveform")
            .overlay(alignment: .topLeading) {
                if model.isFrozen {
                    FrozenBadge { model.toggleFreeze() }
                        .padding(8)
                }
            }
            .overlay {
                if let message = model.message {
                    OverlayMessage(symbol: message.symbol, text: message.text)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var historyPanel: some View {
        Panel("Loudness", accessory: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    LegendSwatch(color: Theme.accent, label: "Short-term", width: 2)
                    LegendSwatch(color: .white.opacity(0.4), label: "Momentary", width: 1)
                    LegendSwatch(color: .white.opacity(0.5), label: "Integrated", width: 1, dashed: true)
                    LegendSwatch(color: Theme.warn, label: "Target \(Format.loudness(settings.target))", width: 1, dashed: true)
                }
                HStack(spacing: 10) {
                    LegendSwatch(color: Theme.accent, label: "Short", width: 2)
                    LegendSwatch(color: .white.opacity(0.4), label: "Mom.", width: 1)
                }
                EmptyView()
            }
        }) {
            ZStack {
                LoudnessHistoryGrid(target: settings.target)
                Live { frame in
                    LoudnessHistoryView(history: frame.snapshot.history,
                                        endIndex: frame.snapshot.historyIndex,
                                        head: frame.head,
                                        columnRate: frame.snapshot.columnRate,
                                        window: settings.window,
                                        integrated: frame.snapshot.integrated)
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            Live(fps: 12) { readouts($0) }
            Panel("Levels") {
                ZStack {
                    BarMetersScale(target: settings.target)
                    Live { frame in
                        BarMetersView(frame: frame, target: settings.target)
                    }
                    Live(fps: 12) { frame in
                        BarMetersReadouts(frame: frame)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .help("L / R: true peak per channel (dB). MOM / S-T: momentary (400 ms) and short-term (3 s) loudness (LUFS). The yellow line marks your loudness target.")
        }
    }

    private func readouts(_ frame: DisplayFrame) -> some View {
        let s = frame.snapshot
        let psr = s.truePeakRecent - s.shortTerm
        let plr = s.truePeakMax - s.integrated
        return VStack(spacing: 10) {
            Panel("Loudness") {
                HStack(alignment: .top, spacing: 8) {
                    BigReadout(title: "Short-term", value: s.shortTerm, target: settings.target)
                    BigReadout(title: "Integrated", value: s.integrated, target: settings.target)
                }
            }
            Panel("Dynamics") {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        StatTile(title: "Momentary", value: Format.loudness(s.momentary), unit: "LUFS")
                            .help(Self.tips.momentary)
                        StatTile(title: "Max Short", value: Format.loudness(s.maxShortTerm), unit: "LUFS")
                            .help(Self.tips.maxShort)
                    }
                    GridRow {
                        StatTile(title: "True Peak", value: Format.loudness(s.truePeakMax), unit: "dBTP",
                                 tint: s.truePeakMax > 0 ? Theme.hot : s.truePeakMax > -1 ? Theme.warn : Theme.text)
                            .help(Self.tips.truePeak)
                        StatTile(title: "LRA", value: s.integrated.isFinite ? Format.lu(s.loudnessRange) : "—", unit: "LU")
                            .help(Self.tips.lra)
                    }
                    GridRow {
                        StatTile(title: "PSR", value: psr.isFinite && s.shortTerm > -99 ? Format.lu(psr) : "—", unit: "LU",
                                 tint: dynamicsTint(psr))
                            .help(Self.tips.psr)
                        StatTile(title: "PLR", value: plr.isFinite && s.integrated > -99 ? Format.lu(plr) : "—", unit: "LU",
                                 tint: dynamicsTint(plr))
                            .help(Self.tips.plr)
                    }
                }
            }
            .help([Self.tips.momentary, Self.tips.maxShort, Self.tips.truePeak,
                   Self.tips.lra, Self.tips.psr, Self.tips.plr].joined(separator: "\n"))
        }
    }

    /// Tooltips for the Dynamics tiles (each tile has its own; the panel shows them all).
    static let tips = (
        momentary: "Momentary: loudness of the last 400 ms (LUFS).",
        maxShort: "Max Short: loudest short-term (3 s) reading since reset (LUFS).",
        truePeak: "True Peak: highest inter-sample peak since reset (dBTP). Amber above −1, red above 0.",
        lra: "LRA: loudness range — how much the loudness varies over the track (LU). Lower = more compressed.",
        psr: "PSR: true peak over the last 3 s minus short-term loudness (LU). Under 8 = heavily limited, under 6 = crushed.",
        plr: "PLR: max true peak minus integrated loudness (LU). Lower = more compressed / limited."
    )

    /// PSR/PLR below ~6 LU means heavy limiting; below ~8 is "loud master" territory.
    private func dynamicsTint(_ v: Double) -> Color {
        guard v.isFinite else { return Theme.text }
        return v < 6 ? Theme.hot : v < 8 ? Theme.warn : Theme.text
    }
}

// MARK: - Controls (used in the app toolbar and the plug-in header)

public struct TimeWindowPicker: View {
    @EnvironmentObject private var model: MeterModel
    public init() {}
    public var body: some View {
        Picker("Time", selection: $model.settings.window) {
            Text("5s").tag(5.0)
            Text("10s").tag(10.0)
            Text("30s").tag(30.0)
            Text("60s").tag(60.0)
        }
        .pickerStyle(.segmented)
        .help("Visible time window")
    }
}

/// Compact LIN | dB switch for the waveform amplitude scale (sits in the waveform panel's title bar).
public struct ScalePicker: View {
    @EnvironmentObject private var model: MeterModel
    public init() {}
    public var body: some View {
        HStack(spacing: 0) {
            chip("LIN", log: false)
            chip("dB", log: true)
        }
        .padding(1)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.05)))
        .help("Waveform amplitude scale: linear or decibels")
    }

    private func chip(_ title: String, log: Bool) -> some View {
        let selected = model.settings.logScale == log
        return Button {
            model.settings.logScale = log
        } label: {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(selected ? Theme.text : Theme.label)
                .padding(.horizontal, 7)
                .frame(height: 12)
                .background(Capsule().fill(selected ? Color.white.opacity(0.16) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

public struct TargetMenu: View {
    @EnvironmentObject private var model: MeterModel
    public init() {}
    public var body: some View {
        Menu {
            ForEach(MeterModel.targets, id: \.0) { name, value in
                Button {
                    model.settings.target = value
                } label: {
                    if model.settings.target == value {
                        Label("\(name)  (\(Format.loudness(value)))", systemImage: "checkmark")
                    } else {
                        Text("\(name)  (\(Format.loudness(value)))")
                    }
                }
            }
            Divider()
            Stepper("Custom: \(Format.loudness(model.settings.target)) LUFS",
                    value: $model.settings.target, in: -36...(-4), step: 0.5)
        } label: {
            Label("Target \(Format.loudness(model.settings.target))", systemImage: "scope")
                .labelStyle(.titleAndIcon)
        }
        .help("Loudness target")
    }
}

/// Same choices as `TimeWindowPicker`, as a compact menu for narrow layouts.
public struct TimeWindowMenu: View {
    @EnvironmentObject private var model: MeterModel
    public init() {}
    public var body: some View {
        Menu {
            Picker("Time", selection: $model.settings.window) {
                Text("5 seconds").tag(5.0)
                Text("10 seconds").tag(10.0)
                Text("30 seconds").tag(30.0)
                Text("60 seconds").tag(60.0)
            }
            .pickerStyle(.inline)
        } label: {
            Label("\(Int(model.settings.window))s", systemImage: "clock")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Visible time window")
    }
}

public struct FreezeButton: View {
    @EnvironmentObject private var model: MeterModel
    var showsTitle: Bool
    public init(showsTitle: Bool = true) { self.showsTitle = showsTitle }
    public var body: some View {
        Button {
            model.toggleFreeze()
        } label: {
            Label(model.isFrozen ? "Resume" : "Freeze", systemImage: model.isFrozen ? "play.fill" : "snowflake")
                .labelStyle(TitleOrIconLabelStyle(showsTitle: showsTitle))
                .foregroundStyle(model.isFrozen ? Theme.accent : Color.primary)
        }
        .help(model.isFrozen ? "Resume the live waveform (F)" : "Freeze the waveform and loudness graph (F)")
    }
}

/// Toggle for the loudness graph. (The sidebar switches to a top strip automatically when space runs out.)
public struct LayoutButtons: View {
    @EnvironmentObject private var model: MeterModel
    public init() {}
    public var body: some View {
        Button {
            model.settings.showHistory.toggle()
        } label: {
            Label("Loudness Graph", systemImage: "chart.xyaxis.line")
                .labelStyle(.iconOnly)
                .foregroundStyle(model.settings.showHistory ? Theme.accent : Color.primary.opacity(0.6))
        }
        .help(model.settings.showHistory ? "Hide loudness graph" : "Show loudness graph")
    }
}

struct TitleOrIconLabelStyle: LabelStyle {
    let showsTitle: Bool
    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
            HStack(spacing: 4) { configuration.icon; configuration.title }
        } else {
            configuration.icon
        }
    }
}

// MARK: - Pieces

/// Horizontal drag handle that resizes the panel below it.
struct ResizeDivider: View {
    let height: CGFloat
    let range: ClosedRange<CGFloat>
    let onChange: (Double) -> Void
    @State private var startHeight: CGFloat?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(hovering || startHeight != nil ? 0.35 : 0.12))
                .frame(width: 40, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startHeight ?? height
                    if startHeight == nil { startHeight = height }
                    let h = min(range.upperBound, max(range.lowerBound, start - value.translation.height))
                    onChange(Double(h))
                }
                .onEnded { _ in startHeight = nil }
        )
        .help("Drag to resize the waveform and loudness graph")
    }
}

struct FrozenBadge: View {
    let resume: () -> Void
    var body: some View {
        Button(action: resume) {
            HStack(spacing: 6) {
                Image(systemName: "snowflake")
                Text("FROZEN").tracking(0.8)
                Text("· click to resume live").foregroundStyle(Theme.label)
            }
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.35)))
        }
        .buttonStyle(.plain)
    }
}

/// Single-row readouts used when the sidebar is collapsed.
struct CompactReadouts: View {
    @EnvironmentObject private var model: MeterModel
    let frame: DisplayFrame

    var body: some View {
        let s = frame.snapshot
        let psr = s.truePeakRecent - s.shortTerm
        let target = model.settings.target
        HStack(spacing: 6) {
            CompactStat(title: "Short-term", value: Format.loudness(s.shortTerm), unit: "LUFS",
                        tint: deltaTint(s.shortTerm, target))
            CompactStat(title: "Integrated", value: Format.loudness(s.integrated), unit: "LUFS",
                        tint: deltaTint(s.integrated, target))
            CompactStat(title: "True Peak", value: Format.loudness(s.truePeakMax), unit: "dBTP",
                        tint: s.truePeakMax > 0 ? Theme.hot : s.truePeakMax > -1 ? Theme.warn : Theme.text)
            CompactStat(title: "PSR", value: psr.isFinite && s.shortTerm > -99 ? Format.lu(psr) : "—", unit: "LU",
                        tint: psr.isFinite ? (psr < 6 ? Theme.hot : psr < 8 ? Theme.warn : Theme.text) : Theme.text)
            CompactStat(title: "LRA", value: s.integrated.isFinite ? Format.lu(s.loudnessRange) : "—", unit: "LU")
        }
    }

    private func deltaTint(_ v: Double, _ target: Double) -> Color {
        guard v.isFinite, v > -99 else { return Theme.text }
        let d = v - target
        return abs(d) <= 1 ? Theme.good : d > 0 ? Theme.warn : Theme.text
    }
}

struct CompactStat: View {
    let title: String
    let value: String
    let unit: String
    var tint: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.label)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(Theme.mono(16)).foregroundStyle(tint)
                Text(unit).font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// Re-renders its content on the display clock (or at `fps`) with the latest meter frame.
/// Only these leaves animate, so the rest of the window isn't re-laid out every frame.
struct Live<Content: View>: View {
    @EnvironmentObject private var model: MeterModel
    var fps: Double = 60
    @ViewBuilder let content: (DisplayFrame) -> Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps, paused: !model.isActive)) { timeline in
            content(fps >= 60 ? model.frame(at: timeline.date) : model.latestFrame)
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: MeterModel
    let frame: DisplayFrame

    var body: some View {
        let s = frame.snapshot
        let clipped = s.truePeakMax > 0
        let receiving = model.isActive && s.lastSignalTime > 0
            && CFAbsoluteTimeGetCurrent() - s.lastSignalTime < 0.35
        let light = receiving ? Theme.good : Theme.hot
        HStack(spacing: 8) {
            Circle()
                .fill(light)
                .frame(width: 6, height: 6)
                .shadow(color: light.opacity(0.8), radius: 3)
            Text(!model.isActive ? "PAUSED" : receiving ? "LIVE" : "NO SIGNAL")
                .font(.system(size: 9.5, weight: .bold)).tracking(0.8)
                .foregroundStyle(receiving ? Theme.text : Theme.label)
                .help(receiving ? "Receiving audio" : model.isActive ? "No audio is arriving (silence or playback stopped)" : "Metering is paused")
            separator
            Text(model.sampleRate > 0 ? String(format: "%.1f kHz", model.sampleRate / 1000) : "— kHz")
                .help("Sample rate of the audio being measured (the output device / host rate). "
                      + "macOS converts music to this rate, so a 48 kHz file shows the device's rate unless "
                      + "you set the device to 48 kHz in Audio MIDI Setup.")
            if !model.statusDetail.isEmpty {
                separator
                Text(model.statusDetail)
            }
            Spacer()
            Text("Measured \(Self.duration(s.measuredSeconds))")
            Button {
                model.resetStatistics()
            } label: {
                Text("CLIP")
                    .font(.system(size: 9, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(clipped ? Color.white : Theme.faint)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(clipped ? Theme.hot : Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Lights when true peak exceeds 0 dBTP. Click to reset.")
        }
        .font(Theme.mono(10, .medium))
        .foregroundStyle(Theme.label)
        .padding(.horizontal, 14)
        .frame(height: 28)
    }

    private var separator: some View {
        Text("·").foregroundStyle(Theme.faint)
    }

    static func duration(_ seconds: Double) -> String {
        let t = Int(seconds)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct BandLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            LegendDot(rgb: Theme.bandLow, label: "Low")
            LegendDot(rgb: Theme.bandMid, label: "Mid")
            LegendDot(rgb: Theme.bandHigh, label: "High")
        }
    }
}

struct LegendDot: View {
    let rgb: SIMD3<Double>
    let label: String
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color(red: rgb.x, green: rgb.y, blue: rgb.z)).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.label)
        }
    }
}

struct LegendSwatch: View {
    let color: Color
    let label: String
    let width: CGFloat
    var dashed = false
    var body: some View {
        HStack(spacing: 4) {
            Path { p in p.move(to: CGPoint(x: 0, y: 3)); p.addLine(to: CGPoint(x: 12, y: 3)) }
                .stroke(color, style: StrokeStyle(lineWidth: width, dash: dashed ? [1, 2] : []))
                .frame(width: 12, height: 6)
            Text(label).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.label)
        }
    }
}

struct OverlayMessage: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: 420)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.stroke))
    }
}
