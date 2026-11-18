import Foundation

/// One horizontal slice of the scrolling waveform (≈5 ms of audio, mid channel).
public struct WaveColumn: Sendable {
    public var min: Float = 0
    public var max: Float = 0
    public var rms: Float = 0
    /// Band energies used to colour the waveform (low / mid / high).
    public var low: Float = 0
    public var mid: Float = 0
    public var high: Float = 0
}

/// Loudness readings taken every 100 ms.
public struct LoudnessPoint: Sendable {
    public var momentary: Float
    public var shortTerm: Float
}

public struct MeterSnapshot: Sendable {
    public var sampleRate: Double = 0
    /// Waveform columns per second.
    public var columnRate: Double = 200
    public var momentary: Double = -.infinity
    public var shortTerm: Double = -.infinity
    public var integrated: Double = -.infinity
    public var loudnessRange: Double = 0
    public var maxMomentary: Double = -.infinity
    public var maxShortTerm: Double = -.infinity
    /// Highest true peak since reset, dBTP.
    public var truePeakMax: Double = -.infinity
    /// Highest true peak over the last 3 s, dBTP (used for PSR).
    public var truePeakRecent: Double = -.infinity
    /// Sample peaks since the previous snapshot (linear).
    public var peakL: Float = 0
    public var peakR: Float = 0
    /// True peaks since the previous snapshot (linear).
    public var truePeakL: Float = 0
    public var truePeakR: Float = 0
    public var columns: [WaveColumn] = []
    public var history: [LoudnessPoint] = []
    /// Total waveform columns produced since `configure` (absolute index just past `columns.last`).
    public var columnIndex = 0
    /// Total loudness points produced since `configure` (absolute index just past `history.last`).
    public var historyIndex = 0
    /// Seconds of audio measured since reset.
    public var measuredSeconds: Double = 0
    /// Wall-clock time (CFAbsoluteTime) of the last block containing signal above −70 dBFS; 0 = never.
    public var lastSignalTime: Double = 0

    public init() {}
}

/// EBU R128 / ITU-R BS.1770-4 loudness meter plus waveform analysis.
/// `process` is called from the audio thread, `snapshot` from the UI; both are lock-protected.
public final class Analyzer: @unchecked Sendable {
    public static let columnsPerSecond = 200.0
    public static let historySeconds = 125.0

    private let lock = NSLock()

    public private(set) var sampleRate: Double = 48_000

    // K-weighting filters
    private var shelfL = Biquad.kWeightingShelf(sampleRate: 48_000)
    private var shelfR = Biquad.kWeightingShelf(sampleRate: 48_000)
    private var hpL = Biquad.kWeightingHighPass(sampleRate: 48_000)
    private var hpR = Biquad.kWeightingHighPass(sampleRate: 48_000)

    // True peak
    private let tpL = TruePeakDetector()
    private let tpR = TruePeakDetector()

    // 100 ms sub-blocks; momentary = 4 blocks, short-term = 30 blocks.
    private var subLength = 4800
    private var subCount = 0
    private var subSum = 0.0
    private var subTruePeak: Float = 0
    private var subPowers = [Double](repeating: 0, count: 30)
    private var subTruePeaks = [Float](repeating: 0, count: 30)
    private var subIndex = 0
    private var subFilled = 0
    private var totalSubBlocks = 0

    // Readings
    private var momentary = -Double.infinity
    private var shortTerm = -Double.infinity
    private var integrated = -Double.infinity
    private var loudnessRange = 0.0
    private var maxMomentary = -Double.infinity
    private var maxShortTerm = -Double.infinity
    private var truePeakMax: Float = 0
    private var truePeakRecent: Float = 0

    // Gating histograms, 0.1 LU bins from -70 to +10 LUFS.
    private static let binCount = 800
    private var gateCount = [Int](repeating: 0, count: binCount)
    private var gateSum = [Double](repeating: 0, count: binCount)
    private var gateTotalCount = 0
    private var gateTotalSum = 0.0
    private var stCount = [Int](repeating: 0, count: binCount)
    private var stSum = [Double](repeating: 0, count: binCount)
    private var stTotalCount = 0
    private var stTotalSum = 0.0

    /// −70 dBFS: below this a block counts as silence (Live sends digital silence when stopped).
    private static let signalThreshold: Float = 0.000316
    private var lastSignalTime: Double = 0

    // Peaks accumulated between snapshots
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var readTPL: Float = 0
    private var readTPR: Float = 0

    // Waveform
    private var samplesPerColumn = 240
    private var colCount = 0
    private var colMin: Float = 0
    private var colMax: Float = 0
    private var colSq: Float = 0
    private var colLow: Float = 0
    private var colMid: Float = 0
    private var colHigh: Float = 0
    private var lowA = OnePole(cutoff: 220, sampleRate: 48_000)
    private var lowB = OnePole(cutoff: 220, sampleRate: 48_000)
    private var midA = OnePole(cutoff: 2_600, sampleRate: 48_000)
    private var midB = OnePole(cutoff: 2_600, sampleRate: 48_000)
    private var columns = Ring<WaveColumn>(capacity: Int(columnsPerSecond * historySeconds), fill: WaveColumn())
    private var totalColumns = 0
    private var totalHistory = 0
    private var history = Ring<LoudnessPoint>(capacity: Int(historySeconds * 10), fill: LoudnessPoint(momentary: -200, shortTerm: -200))

    public init(sampleRate: Double = 48_000) {
        configure(sampleRate: sampleRate)
    }

    /// Re-derives all filters for a sample rate and clears every measurement.
    public func configure(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        self.sampleRate = sampleRate
        shelfL = .kWeightingShelf(sampleRate: sampleRate)
        shelfR = .kWeightingShelf(sampleRate: sampleRate)
        hpL = .kWeightingHighPass(sampleRate: sampleRate)
        hpR = .kWeightingHighPass(sampleRate: sampleRate)
        lowA = OnePole(cutoff: 220, sampleRate: sampleRate)
        lowB = lowA
        midA = OnePole(cutoff: 2_600, sampleRate: sampleRate)
        midB = midA
        subLength = max(1, Int((sampleRate * 0.1).rounded()))
        samplesPerColumn = max(1, Int((sampleRate / Self.columnsPerSecond).rounded()))
        resetLocked(clearWaveform: true)
    }

    /// Clears loudness statistics (integrated, LRA, maxima). Keeps the waveform scrolling.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        resetLocked(clearWaveform: false)
    }

    private func resetLocked(clearWaveform: Bool) {
        shelfL.reset(); shelfR.reset(); hpL.reset(); hpR.reset()
        tpL.reset(); tpR.reset()
        subCount = 0; subSum = 0; subTruePeak = 0
        for i in 0..<30 { subPowers[i] = 0; subTruePeaks[i] = 0 }
        subIndex = 0; subFilled = 0; totalSubBlocks = 0
        momentary = -.infinity; shortTerm = -.infinity; integrated = -.infinity
        loudnessRange = 0
        maxMomentary = -.infinity; maxShortTerm = -.infinity
        truePeakMax = 0; truePeakRecent = 0
        for i in 0..<Self.binCount {
            gateCount[i] = 0; gateSum[i] = 0; stCount[i] = 0; stSum[i] = 0
        }
        gateTotalCount = 0; gateTotalSum = 0; stTotalCount = 0; stTotalSum = 0
        peakL = 0; peakR = 0; readTPL = 0; readTPR = 0
        if clearWaveform {
            colCount = 0; colMin = 0; colMax = 0; colSq = 0; colLow = 0; colMid = 0; colHigh = 0
            columns.removeAll()
            history.removeAll()
            totalColumns = 0
            totalHistory = 0
        }
    }

    // MARK: Audio thread

    public func process(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        var blockPeak: Float = 0
        for i in 0..<frames {
            let l = left[i]
            let r = right[i]

            // Sample + true peak
            let al = abs(l), ar = abs(r)
            if al > blockPeak { blockPeak = al }
            if ar > blockPeak { blockPeak = ar }
            if al > peakL { peakL = al }
            if ar > peakR { peakR = ar }
            let tl = tpL.process(l)
            let tr = tpR.process(r)
            if tl > readTPL { readTPL = tl }
            if tr > readTPR { readTPR = tr }
            let tp = max(tl, tr)
            if tp > subTruePeak { subTruePeak = tp }

            // K-weighted energy
            let kl = hpL.process(shelfL.process(Double(l)))
            let kr = hpR.process(shelfR.process(Double(r)))
            subSum += kl * kl + kr * kr

            // Waveform column (mid channel) with 3-band energy split
            let m = (l + r) * 0.5
            if colCount == 0 {
                colMin = m; colMax = m
            } else {
                if m < colMin { colMin = m }
                if m > colMax { colMax = m }
            }
            colSq += m * m
            let lo = lowB.process(lowA.process(m))
            let lowMid = midB.process(midA.process(m))
            let mid = lowMid - lo
            let hi = m - lowMid
            colLow += lo * lo
            colMid += mid * mid
            colHigh += hi * hi
            colCount += 1
            if colCount == samplesPerColumn { finishColumn() }

            subCount += 1
            if subCount == subLength { finishSubBlock() }
        }
        if blockPeak > Self.signalThreshold { lastSignalTime = CFAbsoluteTimeGetCurrent() }
    }

    @inline(__always)
    private func finishColumn() {
        let n = Float(colCount)
        columns.append(WaveColumn(
            min: colMin, max: colMax, rms: (colSq / n).squareRoot(),
            low: colLow / n, mid: colMid / n, high: colHigh / n
        ))
        totalColumns += 1
        colCount = 0; colSq = 0; colLow = 0; colMid = 0; colHigh = 0
    }

    private func finishSubBlock() {
        subPowers[subIndex] = subSum / Double(subLength)
        subTruePeaks[subIndex] = subTruePeak
        subIndex = (subIndex + 1) % 30
        if subFilled < 30 { subFilled += 1 }
        totalSubBlocks += 1
        subSum = 0
        subCount = 0
        if subTruePeak > truePeakMax { truePeakMax = subTruePeak }
        subTruePeak = 0

        var recent: Float = 0
        for i in 0..<subFilled where subTruePeaks[i] > recent { recent = subTruePeaks[i] }
        truePeakRecent = recent

        // Momentary (400 ms) – also the gating block for integrated loudness (75 % overlap).
        if subFilled >= 4 {
            var p = 0.0
            for k in 1...4 { p += subPowers[(subIndex - k + 30) % 30] }
            p /= 4
            momentary = lufs(fromPower: p)
            if momentary > maxMomentary { maxMomentary = momentary }
            if momentary >= -70 {
                let b = Self.bin(momentary)
                gateCount[b] += 1; gateSum[b] += p
                gateTotalCount += 1; gateTotalSum += p
                computeIntegrated()
            }
        } else {
            momentary = -.infinity
        }

        // Short-term (3 s)
        if subFilled >= 30 {
            var p = 0.0
            for k in 0..<30 { p += subPowers[k] }
            p /= 30
            shortTerm = lufs(fromPower: p)
            if shortTerm > maxShortTerm { maxShortTerm = shortTerm }
            if shortTerm >= -70 {
                let b = Self.bin(shortTerm)
                stCount[b] += 1; stSum[b] += p
                stTotalCount += 1; stTotalSum += p
                computeLoudnessRange()
            }
        } else {
            shortTerm = -.infinity
        }

        history.append(LoudnessPoint(
            momentary: momentary.isFinite ? Float(momentary) : -200,
            shortTerm: shortTerm.isFinite ? Float(shortTerm) : -200
        ))
        totalHistory += 1
    }

    @inline(__always)
    private static func bin(_ loudness: Double) -> Int {
        min(binCount - 1, max(0, Int((loudness + 70) * 10)))
    }

    /// Two-stage gating: absolute −70 LUFS, then relative −10 LU.
    private func computeIntegrated() {
        guard gateTotalCount > 0 else { integrated = -.infinity; return }
        let relative = lufs(fromPower: gateTotalSum / Double(gateTotalCount)) - 10
        let start = Self.bin(relative)
        var sum = 0.0, count = 0
        for b in start..<Self.binCount {
            sum += gateSum[b]; count += gateCount[b]
        }
        integrated = count > 0 ? lufs(fromPower: sum / Double(count)) : -.infinity
    }

    /// EBU Tech 3342: short-term values gated at −70 LUFS and −20 LU, 10th–95th percentile spread.
    private func computeLoudnessRange() {
        guard stTotalCount > 0 else { loudnessRange = 0; return }
        let relative = lufs(fromPower: stTotalSum / Double(stTotalCount)) - 20
        let start = Self.bin(relative)
        var n = 0
        for b in start..<Self.binCount { n += stCount[b] }
        guard n > 1 else { loudnessRange = 0; return }
        let lowTarget = Int((Double(n - 1) * 0.10).rounded())
        let highTarget = Int((Double(n - 1) * 0.95).rounded())
        var cumulative = 0
        var low: Double?
        var high: Double?
        for b in start..<Self.binCount {
            cumulative += stCount[b]
            let value = Double(b) / 10 - 70 + 0.05
            if low == nil, cumulative > lowTarget { low = value }
            if high == nil, cumulative > highTarget { high = value; break }
        }
        loudnessRange = max(0, (high ?? 0) - (low ?? 0))
    }

    // MARK: UI thread

    /// Copies the current state. `columnCount` / `historyCount` limit how much waveform history is returned.
    public func snapshot(columnCount: Int, historyCount: Int) -> MeterSnapshot {
        lock.lock(); defer { lock.unlock() }
        var s = MeterSnapshot()
        s.sampleRate = sampleRate
        s.columnRate = sampleRate / Double(samplesPerColumn)
        s.momentary = momentary
        s.shortTerm = shortTerm
        s.integrated = integrated
        s.loudnessRange = loudnessRange
        s.maxMomentary = maxMomentary
        s.maxShortTerm = maxShortTerm
        s.truePeakMax = truePeakMax > 0 ? 20 * log10(Double(truePeakMax)) : -.infinity
        s.truePeakRecent = truePeakRecent > 0 ? 20 * log10(Double(truePeakRecent)) : -.infinity
        s.peakL = peakL; s.peakR = peakR
        s.truePeakL = readTPL; s.truePeakR = readTPR
        peakL = 0; peakR = 0; readTPL = 0; readTPR = 0
        s.columns = columns.suffix(columnCount)
        s.history = history.suffix(historyCount)
        s.lastSignalTime = lastSignalTime
        s.columnIndex = totalColumns
        s.historyIndex = totalHistory
        s.measuredSeconds = Double(totalSubBlocks) * 0.1
        return s
    }
}
