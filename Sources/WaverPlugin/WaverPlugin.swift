import Foundation
import WaverCore
import WaverUI

/// One plug-in instance: the analyser fed from the render thread plus per-instance settings.
final class WaverPlugin: @unchecked Sendable {
    let analyzer = Analyzer()

    private let lock = NSLock()
    private var _settings = MeterSettings()
    /// Read on the render thread without locking (single Bool).
    private var resetOnPlay = true
    private var wasPlaying = false
    private var prepared = false

    /// -1 unknown, 0 stopped, 1 playing. Written by the render thread, read by the UI.
    private(set) var transportState: Int32 = -1
    private(set) var sampleRate: Double = 0

    /// UI model, created lazily on the main thread and kept for the instance's lifetime.
    private var model: MeterModel?

    var settings: MeterSettings {
        get { lock.lock(); defer { lock.unlock() }; return _settings }
        set {
            lock.lock(); _settings = newValue; lock.unlock()
            resetOnPlay = newValue.resetOnPlay
        }
    }

    func prepare(sampleRate: Double) {
        if !prepared || sampleRate != analyzer.sampleRate {
            analyzer.configure(sampleRate: sampleRate)
        }
        prepared = true
        self.sampleRate = sampleRate
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.model?.sampleRate = sampleRate }
        }
    }

    func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, transport: Int32) {
        let playing = transport == 1
        if playing && !wasPlaying && resetOnPlay {
            analyzer.reset()
        }
        wasPlaying = playing
        transportState = transport
        analyzer.process(left: left, right: right, frames: frames)
    }

    func restore(_ newSettings: MeterSettings) {
        settings = newSettings
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.model?.settings = newSettings }
        }
    }

    @MainActor
    func makeModel() -> MeterModel {
        if let model { return model }
        let m = MeterModel(analyzer: analyzer, settings: settings)
        m.isActive = true
        m.sampleRate = sampleRate
        m.onSettingsChange = { [weak self] in self?.settings = $0 }
        model = m
        return m
    }
}

// MARK: - C entry points (called from WaverAU.c)

@_cdecl("WaverPluginCreate")
public func WaverPluginCreate() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(WaverPlugin()).toOpaque()
}

@_cdecl("WaverPluginDestroy")
public func WaverPluginDestroy(_ p: UnsafeMutableRawPointer) {
    Unmanaged<WaverPlugin>.fromOpaque(p).release()
}

@_cdecl("WaverPluginPrepare")
public func WaverPluginPrepare(_ p: UnsafeMutableRawPointer, _ sampleRate: Double) {
    Unmanaged<WaverPlugin>.fromOpaque(p).takeUnretainedValue().prepare(sampleRate: sampleRate)
}

@_cdecl("WaverPluginProcess")
public func WaverPluginProcess(_ p: UnsafeMutableRawPointer, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>,
                               _ frames: UInt32, _ transport: Int32) {
    Unmanaged<WaverPlugin>.fromOpaque(p).takeUnretainedValue()
        .process(left: left, right: right, frames: Int(frames), transport: transport)
}

@_cdecl("WaverPluginCopyState")
public func WaverPluginCopyState(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let plugin = Unmanaged<WaverPlugin>.fromOpaque(p).takeUnretainedValue()
    let dict = plugin.settings.dictionary as NSDictionary
    return Unmanaged.passRetained(dict).toOpaque()
}

@_cdecl("WaverPluginSetState")
public func WaverPluginSetState(_ p: UnsafeMutableRawPointer, _ state: UnsafeRawPointer) {
    let plugin = Unmanaged<WaverPlugin>.fromOpaque(p).takeUnretainedValue()
    let dict = Unmanaged<NSDictionary>.fromOpaque(state).takeUnretainedValue()
    if let d = dict as? [String: Any] {
        plugin.restore(MeterSettings(dictionary: d))
    }
}
