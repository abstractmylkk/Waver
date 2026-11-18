import CoreAudio
import SwiftUI
import WaverCore
import WaverUI

/// Standalone-app controller: owns audio capture and source selection, feeds the shared `MeterModel`.
@MainActor
final class MeterEngine: ObservableObject {
    @Published private(set) var sources: [AudioSource] = [.systemAudio]
    @Published private(set) var selected: AudioSource = .systemAudio
    @Published private(set) var isRunning = false {
        didSet { model.isActive = isRunning; updateMessage() }
    }
    @Published var errorMessage: String? { didSet { updateMessage() } }

    let model: MeterModel
    private let capture = AudioCapture()
    private let defaults = UserDefaults.standard
    private var listeners: [PropertyListener] = []
    private var deviceListeners: [PropertyListener] = []

    init(startCapture: Bool = true) {
        var settings = MeterSettings()
        if let d = defaults.dictionary(forKey: "settings") { settings = MeterSettings(dictionary: d) }
        model = MeterModel(analyzer: Analyzer(), settings: settings)
        model.onSettingsChange = { [defaults] in defaults.set($0.dictionary, forKey: "settings") }

        refreshSources()
        let lastID = defaults.string(forKey: "source")
        if let match = sources.first(where: { $0.id == lastID }) { selected = match }

        listeners = [
            PropertyListener(object: .system, selector: kAudioHardwarePropertyDevices) { [weak self] in
                self?.refreshSources()
            },
            PropertyListener(object: .system, selector: kAudioHardwarePropertyProcessObjectList) { [weak self] in
                self?.refreshSources()
            },
            PropertyListener(object: .system, selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                guard let self, self.isRunning, self.selected.isTap else { return }
                self.start() // follow the new output device
            },
        ]
        if startCapture { start() }
    }

    /// Used by the offscreen snapshot mode.
    func markRunningForPreview(sampleRate: Double) {
        model.sampleRate = sampleRate
        isRunning = true
    }

    func refreshSources() {
        sources = [.systemAudio] + AudioSources.applications() + AudioSources.inputDevices()
    }

    var applicationSources: [AudioSource] { sources.filter { if case .application = $0 { return true }; return false } }
    var inputSources: [AudioSource] { sources.filter { if case .inputDevice = $0 { return true }; return false } }

    func select(_ source: AudioSource) {
        selected = source
        defaults.set(source.id, forKey: "source")
        start()
    }

    func toggleRunning() {
        isRunning ? stop() : start()
    }

    func start() {
        let source = selected
        if case .inputDevice = source {
            Task {
                guard await AudioCapture.requestMicrophoneAccess() else {
                    self.stop()
                    self.errorMessage = CaptureError.microphoneDenied.errorDescription
                    return
                }
                self.begin(source)
            }
        } else {
            begin(source)
        }
    }

    private func begin(_ source: AudioSource) {
        let analyzer = model.analyzer
        do {
            try capture.start(source) { l, r, n in
                analyzer.process(left: l, right: r, frames: n)
            }
            if capture.sampleRate != analyzer.sampleRate || !isRunning {
                analyzer.configure(sampleRate: capture.sampleRate)
            }
            model.sampleRate = capture.sampleRate
            isRunning = true
            errorMessage = nil
            // Restart when the rate changes (e.g. set in Audio MIDI Setup, or by Live), so the readout
            // and the loudness filters follow. For taps, watch the real output device too: the private
            // capture device doesn't always report its sub-device's rate change.
            var watched = [capture.clockDevice]
            if source.isTap { watched.append(AudioSources.defaultOutputDevice) }
            deviceListeners = watched.map { device in
                PropertyListener(object: device, selector: kAudioDevicePropertyNominalSampleRate) { [weak self] in
                    guard let self, self.isRunning else { return }
                    if device.nominalSampleRate != self.model.sampleRate { self.start() }
                }
            }
        } catch {
            capture.stop()
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        deviceListeners = []
        capture.stop()
        isRunning = false
    }

    private func updateMessage() {
        if let errorMessage {
            model.message = MeterMessage(symbol: "exclamationmark.triangle", text: errorMessage)
        } else if !isRunning {
            model.message = MeterMessage(symbol: "pause.circle", text: "Metering paused")
        } else {
            model.message = nil
        }
    }
}

extension AudioSource {
    var isTap: Bool {
        switch self {
        case .systemAudio, .application: return true
        case .inputDevice: return false
        }
    }
}
