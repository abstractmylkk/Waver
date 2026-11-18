import AVFoundation
import CoreAudio

enum CaptureError: LocalizedError {
    case osStatus(String, OSStatus)
    case noProcess(String)
    case deviceMissing
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .osStatus(let what, let status): return "\(what) failed (OSStatus \(status))."
        case .noProcess(let name): return "\(name) isn't producing audio yet. Start playback, then pick it again."
        case .deviceMissing: return "The selected audio device is no longer available."
        case .microphoneDenied: return "Microphone access is off. Enable Waver in System Settings › Privacy & Security › Microphone."
        }
    }
}

/// Pulls stereo Float32 audio either from a Core Audio process tap (system / single app)
/// or straight from an input device, and hands de-interleaved L/R blocks to `handler`.
final class AudioCapture {
    typealias Handler = (UnsafePointer<Float>, UnsafePointer<Float>, Int) -> Void

    private(set) var sampleRate: Double = 0
    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioDevice = AudioObjectID.unknown
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "app.waver.audio", qos: .userInteractive)

    private var capacity = 0
    private var left: UnsafeMutablePointer<Float>?
    private var right: UnsafeMutablePointer<Float>?
    /// Tap channels sit after any sub-device inputs in the aggregate, so read the last pair.
    private var useLastChannels = false

    /// The device whose clock drives the capture (aggregate or input device).
    var clockDevice: AudioObjectID { ioDevice }

    deinit {
        stop()
        left?.deallocate()
        right?.deallocate()
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(_ source: AudioSource, handler: @escaping Handler) throws {
        stop()
        switch source {
        case .systemAudio:
            try startTap(CATapDescription(stereoGlobalTapButExcludeProcesses: []), handler: handler)
        case .application(let bundleID, let name):
            let objects = AudioSources.processObjects(bundleID: bundleID)
            guard !objects.isEmpty else { throw CaptureError.noProcess(name) }
            try startTap(CATapDescription(stereoMixdownOfProcesses: objects), handler: handler)
        case .inputDevice(let uid, _):
            guard let device = AudioSources.device(uid: uid) else { throw CaptureError.deviceMissing }
            useLastChannels = false
            try startIO(on: device, handler: handler)
        }
    }

    private func startTap(_ description: CATapDescription, handler: @escaping Handler) throws {
        description.uuid = UUID()
        description.name = "Waver"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID.unknown
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw CaptureError.osStatus("Creating the audio tap", status) }
        tapID = tap

        let output = AudioSources.defaultOutputDevice
        guard let outputUID = output.readString(kAudioDevicePropertyDeviceUID) else {
            stop(); throw CaptureError.deviceMissing
        }
        let settings: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Waver Tap",
            kAudioAggregateDeviceUIDKey: AudioSources.tapDeviceUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = AudioObjectID.unknown
        status = AudioHardwareCreateAggregateDevice(settings as CFDictionary, &aggregate)
        guard status == noErr else { stop(); throw CaptureError.osStatus("Creating the capture device", status) }
        aggregateID = aggregate
        useLastChannels = true
        try startIO(on: aggregate, handler: handler)
    }

    private func startIO(on device: AudioObjectID, handler: @escaping Handler) throws {
        ioDevice = device
        sampleRate = device.nominalSampleRate
        if sampleRate <= 0 { sampleRate = 48_000 }

        let lastChannels = useLastChannels
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
            self?.deliver(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)),
                          lastChannels: lastChannels, handler: handler)
        }
        guard status == noErr, let proc else { stop(); throw CaptureError.osStatus("Opening the audio device", status) }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else { stop(); throw CaptureError.osStatus("Starting audio capture", status) }
    }

    private func deliver(_ buffers: UnsafeMutableAudioBufferListPointer, lastChannels: Bool, handler: Handler) {
        var totalChannels = 0
        var frames = 0
        for buffer in buffers where buffer.mNumberChannels > 0 {
            totalChannels += Int(buffer.mNumberChannels)
            if frames == 0, buffer.mData != nil {
                frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels))
            }
        }
        guard totalChannels > 0, frames > 0 else { return }

        if frames > capacity {
            left?.deallocate(); right?.deallocate()
            capacity = max(frames, 4096)
            left = .allocate(capacity: capacity)
            right = .allocate(capacity: capacity)
        }
        guard let left, let right else { return }

        let leftIndex = lastChannels ? max(0, totalChannels - 2) : 0
        let rightIndex = min(leftIndex + 1, totalChannels - 1)
        var base = 0
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            defer { base += channels }
            guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = min(frames, available)
            if (base..<base + channels).contains(leftIndex) {
                let offset = leftIndex - base
                for i in 0..<n { left[i] = data[i * channels + offset] }
            }
            if (base..<base + channels).contains(rightIndex) {
                let offset = rightIndex - base
                for i in 0..<n { right[i] = data[i * channels + offset] }
            }
        }
        handler(left, right, frames)
    }

    func stop() {
        if let procID, ioDevice != .unknown {
            AudioDeviceStop(ioDevice, procID)
            AudioDeviceDestroyIOProcID(ioDevice, procID)
        }
        procID = nil
        ioDevice = .unknown
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }
}
