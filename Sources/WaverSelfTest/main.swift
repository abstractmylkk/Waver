import Foundation
import WaverCore

// Feeds synthetic reference signals through the analyzer and compares against expected values.

func run(_ name: String, sampleRate: Double, seconds: Double, expect: (MeterSnapshot) -> [(String, Double, Double, Double)],
         generator: (Int) -> (Float, Float)) -> Bool {
    let analyzer = Analyzer(sampleRate: sampleRate)
    let total = Int(sampleRate * seconds)
    let chunk = 512
    var l = [Float](repeating: 0, count: chunk)
    var r = [Float](repeating: 0, count: chunk)
    var n = 0
    while n < total {
        let count = min(chunk, total - n)
        for i in 0..<count { (l[i], r[i]) = generator(n + i) }
        analyzer.process(left: l, right: r, frames: count)
        n += count
    }
    let snap = analyzer.snapshot(columnCount: 0, historyCount: 0)
    var ok = true
    print("— \(name) @ \(Int(sampleRate)) Hz")
    for (label, got, want, tolerance) in expect(snap) {
        let pass = abs(got - want) <= tolerance
        ok = ok && pass
        print(String(format: "   %@ %-12@ got %8.2f  want %8.2f ±%.2f", pass ? "✓" : "✗", label, got, want, tolerance))
    }
    return ok
}

var allOK = true
for fs in [44_100.0, 48_000.0, 96_000.0] {
    // EBU Tech 3341 case 1: 1 kHz stereo sine at −23 dBFS → −23 LUFS (M, S, I).
    let a = Float(pow(10, -23.0 / 20))
    allOK = run("1 kHz −23 dBFS", sampleRate: fs, seconds: 20, expect: { s in
        [("Momentary", s.momentary, -23, 0.1), ("Short-term", s.shortTerm, -23, 0.1),
         ("Integrated", s.integrated, -23, 0.1), ("LRA", s.loudnessRange, 0, 0.2)]
    }) { i in
        let v = a * Float(sin(2 * Double.pi * 1000 * Double(i) / fs))
        return (v, v)
    } && allOK

    // EBU Tech 3341 case 2-ish: −33 dBFS → −33 LUFS integrated.
    let b = Float(pow(10, -33.0 / 20))
    allOK = run("1 kHz −33 dBFS", sampleRate: fs, seconds: 20, expect: { s in
        [("Integrated", s.integrated, -33, 0.1)]
    }) { i in
        let v = b * Float(sin(2 * Double.pi * 1000 * Double(i) / fs))
        return (v, v)
    } && allOK

    // EBU Tech 3342 case 1: 20 s at −20 dBFS then 20 s at −30 dBFS → LRA 10 LU.
    let c1 = Float(pow(10, -20.0 / 20)), c2 = Float(pow(10, -30.0 / 20))
    allOK = run("LRA step 10 LU", sampleRate: fs, seconds: 40, expect: { s in
        [("LRA", s.loudnessRange, 10, 1.0)]
    }) { i in
        let amp = Double(i) < fs * 20 ? c1 : c2
        let v = amp * Float(sin(2 * Double.pi * 1000 * Double(i) / fs))
        return (v, v)
    } && allOK

    // True peak: fs/4 sine at 45° phase has samples at 0.707 but a true peak of 1.0 (0 dBTP).
    allOK = run("True peak fs/4", sampleRate: fs, seconds: 2, expect: { s in
        [("True peak", s.truePeakMax, 0, 0.3)]
    }) { i in
        let v = Float(sin(Double.pi / 2 * Double(i) + Double.pi / 4))
        return (v, v)
    } && allOK
}

print(allOK ? "\nALL PASSED" : "\nFAILURES")
exit(allOK ? 0 : 1)
