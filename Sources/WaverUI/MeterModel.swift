import SwiftUI
import WaverCore

/// Everything a single rendered frame needs, including meter ballistics.
public struct DisplayFrame {
    public var snapshot = MeterSnapshot()
    /// Absolute waveform-column position shown at the right edge (fractional → smooth scrolling).
    var head: Double = 0
    /// Bar levels in dBTP after peak-meter ballistics.
    var barL: Double = -120
    var barR: Double = -120
    var holdL: Double = -120
    var holdR: Double = -120

    public init() {}
}

/// User-facing display settings (persisted by the app in UserDefaults, by the plug-in in the Live set).
public struct MeterSettings: Equatable {
    public var target: Double = -14
    public var window: Double = 10
    public var logScale = false
    /// Plug-in only: clear integrated/LRA/peaks when the host transport starts.
    public var resetOnPlay = true
    /// Height of the loudness-history panel (drag the divider above it).
    public var historyHeight: Double = 170
    public var showHistory = true
    /// Plug-in editor size.
    public var editorWidth: Double = 1000
    public var editorHeight: Double = 620

    public init() {}

    public var dictionary: [String: Any] {
        ["target": target, "window": window, "logScale": logScale, "resetOnPlay": resetOnPlay,
         "historyHeight": historyHeight, "showHistory": showHistory,
         "editorWidth": editorWidth, "editorHeight": editorHeight]
    }

    public init(dictionary d: [String: Any]) {
        if let v = d["target"] as? Double { target = v }
        if let v = d["window"] as? Double { window = v }
        if let v = d["logScale"] as? Bool { logScale = v }
        if let v = d["resetOnPlay"] as? Bool { resetOnPlay = v }
        if let v = d["historyHeight"] as? Double { historyHeight = v }
        if let v = d["showHistory"] as? Bool { showHistory = v }
        if let v = d["editorWidth"] as? Double { editorWidth = v }
        if let v = d["editorHeight"] as? Double { editorHeight = v }
    }
}

public struct MeterMessage: Equatable {
    public var symbol: String
    public var text: String
    public init(symbol: String, text: String) { self.symbol = symbol; self.text = text }
}

/// Bridges an `Analyzer` to SwiftUI: settings, status, freeze and per-frame meter ballistics.
@MainActor
public final class MeterModel: ObservableObject {
    public let analyzer: Analyzer
    @Published public var settings: MeterSettings { didSet { if settings != oldValue { onSettingsChange?(settings) } } }
    @Published public var isActive = false
    @Published public var sampleRate: Double = 0
    @Published public var message: MeterMessage?
    /// Short status text shown in the status bar (e.g. transport state in the plug-in).
    @Published public var statusDetail = ""
    /// Waveform and loudness graph are held still; numbers and bars keep running.
    @Published public private(set) var isFrozen = false
    public var onSettingsChange: ((MeterSettings) -> Void)?

    public static let targets: [(String, Double)] = [
        ("Club / Loud master", -8), ("Spotify Loud", -11), ("Spotify · YouTube · Tidal", -14),
        ("Apple Music", -16), ("Broadcast EBU R128", -23), ("Broadcast ATSC A/85", -24),
    ]

    // Smooth display clock, in absolute waveform columns.
    private var liveHead: Double = -1
    /// How far the display trails the newest audio, so irregular host buffers never cause stalls.
    private static let displayLag = 0.045

    private struct Frozen {
        var columns: [WaveColumn]
        var history: [LoudnessPoint]
        var columnIndex: Int
        var historyIndex: Int
        var head: Double
    }
    private var frozen: Frozen?

    // Ballistics
    private var lastFrameTime: Double = 0
    private var barL = -120.0, barR = -120.0
    private var holdL = -120.0, holdR = -120.0
    private var holdTimeL = 0.0, holdTimeR = 0.0
    private static let fallRate = 26.0     // dB per second
    private static let holdDuration = 1.6  // seconds

    /// Most recent frame, for low-rate readouts that must not consume peak data.
    public private(set) var latestFrame = DisplayFrame()

    public init(analyzer: Analyzer, settings: MeterSettings = MeterSettings()) {
        self.analyzer = analyzer
        self.settings = settings
    }

    public func resetStatistics() {
        analyzer.reset()
        holdL = -120; holdR = -120
    }

    /// Freezes the waveform and loudness graph on the current picture; unfreezing jumps back to live audio.
    public func toggleFreeze() {
        if isFrozen {
            frozen = nil
            isFrozen = false
        } else {
            // Capture the longest window so switching 5s → 60s while frozen still has data.
            let snap = analyzer.snapshot(columnCount: Int(60 * Analyzer.columnsPerSecond) + 400, historyCount: 620)
            frozen = Frozen(columns: snap.columns, history: snap.history,
                            columnIndex: snap.columnIndex, historyIndex: snap.historyIndex,
                            head: min(latestFrame.head, Double(snap.columnIndex)))
            isFrozen = true
        }
    }

    /// Pulls fresh data from the analyzer and advances the display clock and meter ballistics.
    public func frame(at date: Date) -> DisplayFrame {
        let now = date.timeIntervalSinceReferenceDate
        // Several views render per display tick: they all share one frame.
        if abs(now - lastFrameTime) < 0.004 { return latestFrame }
        let dt = lastFrameTime == 0 ? 0 : min(0.25, max(0, now - lastFrameTime))
        lastFrameTime = now

        let rate = Analyzer.columnsPerSecond
        let columns = Int((settings.window + 0.5) * rate) + 4
        let history = Int(settings.window * 10) + 12
        var snap = analyzer.snapshot(columnCount: columns, historyCount: history)

        // Advance the display clock at wall-clock speed, gently pulled toward the newest audio.
        let rateNow = snap.columnRate
        let latest = Double(snap.columnIndex)
        let desired = latest - Self.displayLag * rateNow
        if liveHead < 0 || latest < liveHead - rateNow || desired - liveHead > rateNow * 0.4 {
            liveHead = max(0, desired) // first frame, reconfigured analyzer, or fell far behind
        } else if isActive {
            liveHead += dt * rateNow
            liveHead += (desired - liveHead) * min(1, dt * 3)
            liveHead = min(liveHead, latest)
        }

        var head = liveHead
        if let frozen {
            snap.columns = frozen.columns
            snap.history = frozen.history
            snap.columnIndex = frozen.columnIndex
            snap.historyIndex = frozen.historyIndex
            head = frozen.head
        }

        func db(_ x: Float) -> Double { x > 0 ? 20 * log10(Double(x)) : -120 }
        func step(_ bar: inout Double, _ hold: inout Double, _ holdTime: inout Double, _ input: Double) {
            bar = max(input, bar - Self.fallRate * dt)
            if input >= hold {
                hold = input; holdTime = now
            } else if now - holdTime > Self.holdDuration {
                hold = max(bar, hold - Self.fallRate * 1.5 * dt)
            }
        }
        if isActive {
            step(&barL, &holdL, &holdTimeL, db(snap.truePeakL))
            step(&barR, &holdR, &holdTimeR, db(snap.truePeakR))
        }
        var frame = DisplayFrame()
        frame.snapshot = snap
        frame.head = head
        frame.barL = barL; frame.barR = barR; frame.holdL = holdL; frame.holdR = holdR
        latestFrame = frame
        return frame
    }
}
