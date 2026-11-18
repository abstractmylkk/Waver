import SwiftUI
import WaverCore
import WaverUI

/// `Waver --snapshot out.png`: feeds a synthetic, limited "track" through the meter and renders
/// the main view offscreen. Used to check layout without screen-recording permission.
@MainActor
enum SnapshotRenderer {
    static func run(output: String, size: CGSize = CGSize(width: 1120, height: 620), frozen: Bool = false) {
        let engine = MeterEngine(startCapture: false)
        let fs = 48_000.0
        engine.model.analyzer.configure(sampleRate: fs)
        engine.markRunningForPreview(sampleRate: fs)

        let seconds = 14.0
        let total = Int(fs * seconds)
        var l = [Float](repeating: 0, count: 512), r = l
        var noise: UInt32 = 1
        var n = 0
        while n < total {
            let count = min(512, total - n)
            for i in 0..<count {
                let t = Double(n + i) / fs
                let beat = t.truncatingRemainder(dividingBy: 0.5)
                let kick = sin(2 * .pi * (48 + 90 * exp(-beat * 30)) * beat) * exp(-beat * 9)
                noise = noise &* 1664525 &+ 1013904223
                let white = Double(Int32(bitPattern: noise)) / Double(Int32.max)
                let hat = white * exp(-(t + 0.25).truncatingRemainder(dividingBy: 0.25) * 60) * 0.35
                let chord = (sin(2 * .pi * 220 * t) + sin(2 * .pi * 277.2 * t) + sin(2 * .pi * 329.6 * t)) * 0.12
                let swell = 0.55 + 0.45 * sin(2 * .pi * t / 7)
                let mix = (kick * 0.9 + hat + chord * swell) * (t > 9 ? 1.6 : 1.0)
                let limited = Float(tanh(mix * 1.4) * 0.93)
                l[i] = limited
                r[i] = limited * 0.97
            }
            engine.model.analyzer.process(left: l, right: r, frames: count)
            n += count
            if n % 4800 < 512 { _ = engine.model.frame(at: Date(timeIntervalSinceReferenceDate: Double(n) / fs)) }
        }
        _ = engine.model.frame(at: Date())
        if frozen { engine.model.toggleFreeze() }

        let view = ContentView()
            .environmentObject(engine)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("render failed"); return
        }
        try? png.write(to: URL(fileURLWithPath: output))
        print("wrote \(output)")
    }
}
