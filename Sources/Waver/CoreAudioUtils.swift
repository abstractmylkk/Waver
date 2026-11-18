import AppKit
import CoreAudio

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 default value: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var result = value
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &result)
        return status == noErr ? result : value
    }

    func readObjectIDs(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    var inputChannelCount: Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    var nominalSampleRate: Double {
        read(kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }
}

/// Registers a Core Audio property listener; returns a token that removes it.
final class PropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, selector: AudioObjectPropertySelector, handler: @escaping () -> Void) {
        self.object = object
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        self.block = { _, _ in DispatchQueue.main.async(execute: handler) }
        AudioObjectAddPropertyListenerBlock(object, &address, .main, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}

// MARK: - Sources

enum AudioSource: Hashable, Identifiable {
    case systemAudio
    case application(bundleID: String, name: String)
    case inputDevice(uid: String, name: String)

    var id: String {
        switch self {
        case .systemAudio: return "system"
        case .application(let bundleID, _): return "app:\(bundleID)"
        case .inputDevice(let uid, _): return "input:\(uid)"
        }
    }

    var displayName: String {
        switch self {
        case .systemAudio: return "System Audio"
        case .application(_, let name): return name
        case .inputDevice(_, let name): return name
        }
    }

    var symbol: String {
        switch self {
        case .systemAudio: return "hifispeaker.2"
        case .application: return "app.badge"
        case .inputDevice: return "mic"
        }
    }
}

enum AudioSources {
    /// UID prefix of the private capture device Waver builds for System Audio / app taps.
    static let tapDeviceUIDPrefix = "app.waver.tap."

    static func inputDevices() -> [AudioSource] {
        AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices).compactMap { id in
            guard id.inputChannelCount > 0,
                  let uid = id.readString(kAudioDevicePropertyDeviceUID),
                  !uid.hasPrefix(tapDeviceUIDPrefix), // Waver's own internal capture device
                  let name = id.readString(kAudioObjectPropertyName) else { return nil }
            return .inputDevice(uid: uid, name: name)
        }
    }

    /// Regular GUI apps that currently have a Core Audio client (Ableton Live sorted first).
    static func applications() -> [AudioSource] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        var result: [AudioSource] = []
        for object in AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList) {
            let pid = object.read(kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != myPID,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            result.append(.application(bundleID: bundleID, name: app.localizedName ?? bundleID))
        }
        return result.sorted { a, b in
            let aLive = a.id.lowercased().contains("ableton"), bLive = b.id.lowercased().contains("ableton")
            if aLive != bLive { return aLive }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// All Core Audio process objects belonging to a bundle (helpers included, e.g. plug-in hosts).
    static func processObjects(bundleID: String) -> [AudioObjectID] {
        AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyProcessObjectList).filter { object in
            if let id = object.readString(kAudioProcessPropertyBundleID), id == bundleID || id.hasPrefix(bundleID + ".") {
                return true
            }
            let pid = object.read(kAudioProcessPropertyPID, default: pid_t(-1))
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
        }
    }

    static func device(uid: String) -> AudioObjectID? {
        AudioObjectID.system.readObjectIDs(kAudioHardwarePropertyDevices).first {
            $0.readString(kAudioDevicePropertyDeviceUID) == uid
        }
    }

    static var defaultOutputDevice: AudioObjectID {
        // The device music plays through (not the alert-sound device).
        AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown)
    }
}
