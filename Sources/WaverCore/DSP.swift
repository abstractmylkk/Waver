import Foundation

// MARK: - Biquad (transposed direct form II)

struct Biquad {
    var b0, b1, b2, a1, a2: Double
    var z1 = 0.0, z2 = 0.0

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }

    /// BS.1770 stage 1: high-shelf "head" filter, derived for any sample rate.
    static func kWeightingShelf(sampleRate fs: Double) -> Biquad {
        let f0 = 1681.974450955533
        let gain = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(.pi * f0 / fs)
        let vh = pow(10.0, gain / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0
        )
    }

    /// BS.1770 stage 2: RLB high-pass.
    static func kWeightingHighPass(sampleRate fs: Double) -> Biquad {
        let f0 = 38.13547087602444
        let q = 0.5003270373238773
        let k = tan(.pi * f0 / fs)
        let d = 1.0 + k / q + k * k
        return Biquad(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (k * k - 1.0) / d,
            a2: (1.0 - k / q + k * k) / d
        )
    }
}

// MARK: - One-pole low-pass (used for the waveform's band colouring)

struct OnePole {
    var a: Float
    var z: Float = 0

    init(cutoff: Double, sampleRate: Double) {
        a = Float(1.0 - exp(-2.0 * .pi * cutoff / sampleRate))
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        z += a * (x - z)
        return z
    }
}

// MARK: - True-peak detector (4x polyphase oversampling, BS.1770-4 Annex 2)

final class TruePeakDetector {
    static let phases = 4
    static let tapsPerPhase = 12

    /// Polyphase coefficients laid out as [phase * tapsPerPhase + k].
    static let coefficients: [Float] = {
        let n = phases * tapsPerPhase
        let center = Double(n - 1) / 2.0
        var h = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = (Double(i) - center) / Double(phases)
            let sinc = t == 0 ? 1.0 : sin(.pi * t) / (.pi * t)
            // Blackman-Harris window
            let x = 2.0 * .pi * Double(i) / Double(n - 1)
            let w = 0.35875 - 0.48829 * cos(x) + 0.14128 * cos(2 * x) - 0.01168 * cos(3 * x)
            h[i] = sinc * w
        }
        // Normalise each phase to unity DC gain.
        var out = [Float](repeating: 0, count: n)
        for p in 0..<phases {
            var sum = 0.0
            for k in 0..<tapsPerPhase { sum += h[p + phases * k] }
            for k in 0..<tapsPerPhase { out[p * tapsPerPhase + k] = Float(h[p + phases * k] / sum) }
        }
        return out
    }()

    private var history = [Float](repeating: 0, count: tapsPerPhase * 2)
    private var pos = 0

    func reset() {
        for i in history.indices { history[i] = 0 }
        pos = 0
    }

    /// Feeds one sample and returns the largest absolute inter-sample value produced.
    @inline(__always)
    func process(_ x: Float) -> Float {
        let taps = Self.tapsPerPhase
        pos = pos == 0 ? taps - 1 : pos - 1
        history[pos] = x
        history[pos + taps] = x
        let start = pos
        return history.withUnsafeBufferPointer { hist in
            Self.coefficients.withUnsafeBufferPointer { c in
                var peak: Float = 0
                for p in 0..<Self.phases {
                    var acc: Float = 0
                    let base = p * taps
                    for k in 0..<taps { acc += c[base + k] * hist[start + k] }
                    peak = max(peak, abs(acc))
                }
                return peak
            }
        }
    }
}

// MARK: - Fixed-capacity ring buffer

struct Ring<T> {
    private var storage: [T]
    private var head = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int, fill: T) {
        self.capacity = capacity
        storage = [T](repeating: fill, count: capacity)
    }

    @inline(__always)
    mutating func append(_ value: T) {
        storage[head] = value
        head += 1
        if head == capacity { head = 0 }
        if count < capacity { count += 1 }
    }

    mutating func removeAll() {
        head = 0
        count = 0
    }

    /// The newest `n` elements, oldest first.
    func suffix(_ n: Int) -> [T] {
        let n = min(n, count)
        guard n > 0 else { return [] }
        var out = [T]()
        out.reserveCapacity(n)
        var i = head - n
        if i < 0 { i += capacity }
        for _ in 0..<n {
            out.append(storage[i])
            i += 1
            if i == capacity { i = 0 }
        }
        return out
    }
}

@inline(__always)
func lufs(fromPower p: Double) -> Double {
    p > 0 ? -0.691 + 10.0 * log10(p) : -.infinity
}
