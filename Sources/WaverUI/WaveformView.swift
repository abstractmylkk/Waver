import SwiftUI
import WaverCore

/// Scrolling, frequency-coloured waveform of the mid signal (newest audio on the right).
/// Rendered as two filled outlines (peak envelope + RMS body) whose colour comes from a horizontal
/// gradient sampled from the band energies, so each frame costs two GPU fills.
struct WaveformView: View {
    let columns: [WaveColumn]
    /// Absolute index just past the last element of `columns`.
    let endIndex: Int
    /// Absolute (fractional) column position drawn at the right edge.
    let head: Double
    let columnRate: Double
    let window: Double
    let logScale: Bool

    static let labelWidth: CGFloat = 30
    static let logRange: Float = 48
    /// One colour stop every N buckets.
    private static let colorEvery = 3

    var body: some View {
        Canvas(rendersAsynchronously: false) { ctx, size in
            let plot = CGRect(x: 0, y: 0, width: max(1, size.width - Self.labelWidth), height: size.height)
            ctx.clip(to: Path(plot))
            let mid = plot.midY
            let half = plot.height / 2 - 1
            let total = max(1, window * columnRate)          // columns across the plot
            let count = max(2, Int(plot.width))              // ~1 bucket per point
            let perBucket = total / Double(count)            // columns per bucket (constant for a given size)
            let pointsPerColumn = Double(plot.width) / total
            let firstIndex = endIndex - columns.count
            let head = min(self.head, Double(endIndex))

            // Buckets are anchored to absolute time (bucket j always holds the same audio), so the
            // outline keeps its shape and simply slides left, instead of being re-sampled every frame.
            let jStart = Int((max(0, head - total) / perBucket).rounded(.down)) - 1
            let jEnd = Int((head / perBucket).rounded(.up))
            guard jEnd > jStart else { return }

            var peakTop = [CGPoint](), peakBottom = [CGPoint]()
            var rmsTop = [CGPoint](), rmsBottom = [CGPoint]()
            peakTop.reserveCapacity(count + 4); peakBottom.reserveCapacity(count + 4)
            rmsTop.reserveCapacity(count + 4); rmsBottom.reserveCapacity(count + 4)
            var stops = [Gradient.Stop]()
            var bodyStops = [Gradient.Stop]()
            var accLow: Float = 0, accMid: Float = 0, accHigh: Float = 0

            columns.withUnsafeBufferPointer { cols in
                for j in jStart...jEnd {
                    var a = Int((Double(j) * perBucket).rounded(.down))
                    var b = Int((Double(j + 1) * perBucket).rounded(.down))
                    if b <= a { b = a + 1 }
                    a = max(a, firstIndex); b = min(b, endIndex)
                    guard a < b else { continue }

                    var mn: Float = 0, mx: Float = 0, sq: Float = 0
                    for k in (a - firstIndex)..<(b - firstIndex) {
                        let c = cols[k]
                        if c.min < mn { mn = c.min }
                        if c.max > mx { mx = c.max }
                        sq += c.rms * c.rms
                        accLow += c.low; accMid += c.mid; accHigh += c.high
                    }
                    let rms = (sq / Float(b - a)).squareRoot()
                    let center = (Double(j) + 0.5) * perBucket
                    let x = plot.maxX - CGFloat((head - center) * pointsPerColumn)

                    let r = CGFloat(Self.map(rms, logScale)) * half
                    peakTop.append(CGPoint(x: x, y: mid - CGFloat(Self.map(mx, logScale)) * half - 0.5))
                    peakBottom.append(CGPoint(x: x, y: mid - CGFloat(Self.map(mn, logScale)) * half + 0.5))
                    rmsTop.append(CGPoint(x: x, y: mid - r))
                    rmsBottom.append(CGPoint(x: x, y: mid + r))

                    let phase = ((j % Self.colorEvery) + Self.colorEvery) % Self.colorEvery
                    if phase == Self.colorEvery - 1 || j == jEnd || stops.isEmpty {
                        let rgb = Self.color(low: accLow, mid: accMid, high: accHigh)
                        let location = min(1, max(0, (x - plot.minX) / plot.width))
                        let edge = rgb * 0.58
                        stops.append(.init(color: Color(red: edge.x, green: edge.y, blue: edge.z), location: location))
                        let body = rgb * 0.94 + SIMD3(repeating: 0.06)
                        bodyStops.append(.init(color: Color(red: body.x, green: body.y, blue: body.z), location: location))
                        accLow = 0; accMid = 0; accHigh = 0
                    }
                }
            }

            if peakTop.count > 1, !stops.isEmpty {
                let start = CGPoint(x: plot.minX, y: 0), end = CGPoint(x: plot.maxX, y: 0)
                ctx.fill(Self.outline(peakTop, peakBottom),
                         with: .linearGradient(Gradient(stops: stops), startPoint: start, endPoint: end))
                ctx.fill(Self.outline(rmsTop, rmsBottom),
                         with: .linearGradient(Gradient(stops: bodyStops), startPoint: start, endPoint: end))
            }

            var centre = Path()
            centre.move(to: CGPoint(x: plot.minX, y: mid))
            centre.addLine(to: CGPoint(x: plot.maxX, y: mid))
            ctx.stroke(centre, with: .color(.white.opacity(0.12)), lineWidth: 1)
        }
    }

    private static func outline(_ top: [CGPoint], _ bottom: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(top)
        for point in bottom.reversed() { p.addLine(to: point) }
        p.closeSubpath()
        return p
    }

    /// Amplitude → normalised display height (signed).
    @inline(__always)
    static func map(_ v: Float, _ logScale: Bool) -> Float {
        guard logScale else { return max(-1, min(1, v)) }
        let a = abs(v)
        guard a > 0 else { return 0 }
        let n = max(0, (20 * log10(a) + logRange) / logRange)
        return v < 0 ? -min(1, n) : min(1, n)
    }

    /// Blends the band colours by energy; highs carry far less energy than lows, so they're weighted up.
    static func color(low: Float, mid: Float, high: Float) -> SIMD3<Double> {
        let l = Double(low.squareRoot())
        let m = Double(mid.squareRoot()) * 1.7
        let h = Double(high.squareRoot()) * 3.2
        let sum = l + m + h
        guard sum > 1e-9 else { return SIMD3(repeating: 0.6) }
        var c = Theme.bandLow * (l / sum) + Theme.bandMid * (m / sum) + Theme.bandHigh * (h / sum)
        let peak = max(c.x, max(c.y, c.z))
        if peak > 0 { c *= 0.97 / peak }
        return c
    }
}

/// Static dB / time grid behind the waveform (redrawn only on resize or setting change).
struct WaveformGrid: View {
    let window: Double
    let logScale: Bool

    /// Minimum vertical distance between scale labels before they are dropped.
    static let minLabelSpacing: CGFloat = 12

    var body: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 0, y: 0, width: max(1, size.width - WaveformView.labelWidth), height: size.height)
            drawGrid(ctx, plot: plot, mid: plot.midY, half: plot.height / 2 - 1, size: size)
        }
    }

    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect, mid: CGFloat, half: CGFloat, size: CGSize) {
        let marks: [Float] = logScale ? [0, -6, -12, -24, -36] : [0, -3, -6, -12, -18]
        var grid = Path()
        var lastLabelY = -CGFloat.infinity
        for db in marks {
            let range = WaveformView.logRange
            let amp = logScale ? max(0, (db + range) / range) : pow(10, db / 20)
            let dy = CGFloat(amp) * half
            for y in [mid - dy, mid + dy] {
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            let label = Text(db == 0 ? "0" : "\(Int(db))")
                .font(Theme.mono(9, .medium))
                .foregroundColor(Theme.faint)
            // Skip labels that would collide with the one above (small windows).
            let labelY = mid - dy + (db == 0 ? 6 : 0)
            if labelY - lastLabelY >= Self.minLabelSpacing {
                ctx.draw(label, at: CGPoint(x: size.width - 4, y: labelY), anchor: .trailing)
                lastLabelY = labelY
            }
        }

        // Time divisions, anchored to "now" at the right edge.
        let step: Double = window <= 5 ? 1 : window <= 10 ? 2 : window <= 30 ? 5 : 10
        var t = step
        while t < window {
            let x = plot.maxX - CGFloat(t / window) * plot.width
            grid.move(to: CGPoint(x: x, y: plot.minY))
            grid.addLine(to: CGPoint(x: x, y: plot.maxY))
            t += step
        }
        ctx.stroke(grid, with: .color(Theme.grid), lineWidth: 1)

        var t2 = step
        var lastLabelX = CGFloat.infinity
        while t2 < window {
            let x = plot.maxX - CGFloat(t2 / window) * plot.width
            if lastLabelX - x >= 36 {
                ctx.draw(Text("−\(Int(t2))s").font(Theme.mono(9, .medium)).foregroundColor(Theme.faint),
                         at: CGPoint(x: x + 3, y: plot.maxY - 3), anchor: .bottomLeading)
                lastLabelX = x
            }
            t2 += step
        }
    }
}

/// Shared vertical mapping for the loudness history layers.
struct HistoryScale {
    static let top = 0.0
    static let bottom = -36.0
    let plot: CGRect

    init(size: CGSize) {
        plot = CGRect(x: 0, y: 6, width: max(1, size.width - WaveformView.labelWidth), height: size.height - 12)
    }

    func y(_ v: Double) -> CGFloat {
        let n = (min(Self.top, max(Self.bottom, v)) - Self.bottom) / (Self.top - Self.bottom)
        return plot.maxY - CGFloat(n) * plot.height
    }
}

/// Static grid, labels and target line for the loudness history.
struct LoudnessHistoryGrid: View {
    let target: Double

    var body: some View {
        Canvas { ctx, size in
            let scale = HistoryScale(size: size)
            let plot = scale.plot
            var grid = Path()
            var lastLabelY = -CGFloat.infinity
            for v in stride(from: HistoryScale.top - 6, through: HistoryScale.bottom, by: -6) {
                grid.move(to: CGPoint(x: plot.minX, y: scale.y(v)))
                grid.addLine(to: CGPoint(x: plot.maxX, y: scale.y(v)))
                if scale.y(v) - lastLabelY >= WaveformGrid.minLabelSpacing {
                    ctx.draw(Text("\(Int(v))").font(Theme.mono(9, .medium)).foregroundColor(Theme.faint),
                             at: CGPoint(x: size.width - 4, y: scale.y(v)), anchor: .trailing)
                    lastLabelY = scale.y(v)
                }
            }
            ctx.stroke(grid, with: .color(Theme.grid), lineWidth: 1)

            var targetLine = Path()
            targetLine.move(to: CGPoint(x: plot.minX, y: scale.y(target)))
            targetLine.addLine(to: CGPoint(x: plot.maxX, y: scale.y(target)))
            ctx.stroke(targetLine, with: .color(Theme.warn.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
    }
}

/// Momentary and short-term loudness over the same time window as the waveform.
struct LoudnessHistoryView: View {
    let history: [LoudnessPoint]
    /// Absolute index just past the last history point.
    let endIndex: Int
    /// Display clock in waveform columns (shared with the waveform so both scroll together).
    let head: Double
    let columnRate: Double
    let window: Double
    let integrated: Double

    var body: some View {
        Canvas { ctx, size in
            let scale = HistoryScale(size: size)
            let plot = scale.plot
            ctx.clip(to: Path(plot))
            func y(_ v: Double) -> CGFloat { scale.y(v) }
            let headTime = head / max(1, columnRate)
            let firstIndex = endIndex - history.count
            func x(_ index: Int) -> CGFloat {
                // Point k describes the 100 ms block ending at (k + 1) × 0.1 s.
                let time = Double(firstIndex + index + 1) * 0.1
                return plot.maxX - CGFloat((headTime - time) / window) * plot.width
            }
            // Lines, broken where there is no reading yet.
            var shortPath = Path(), momentaryPath = Path(), fill = Path()
            var shortOpen = false, momentaryOpen = false
            var fillStart: CGFloat?
            var lastX: CGFloat = 0
            for (i, p) in history.enumerated() {
                let px = x(i)
                if p.shortTerm > -150 {
                    let pt = CGPoint(x: px, y: y(Double(p.shortTerm)))
                    if shortOpen { shortPath.addLine(to: pt); fill.addLine(to: pt) } else {
                        shortPath.move(to: pt)
                        fill.move(to: CGPoint(x: px, y: plot.maxY)); fill.addLine(to: pt)
                        fillStart = px
                    }
                    shortOpen = true
                    lastX = px
                } else if shortOpen {
                    fill.addLine(to: CGPoint(x: lastX, y: plot.maxY)); fill.closeSubpath()
                    shortOpen = false
                }
                if p.momentary > -150 {
                    let pt = CGPoint(x: px, y: y(Double(p.momentary)))
                    if momentaryOpen { momentaryPath.addLine(to: pt) } else { momentaryPath.move(to: pt) }
                    momentaryOpen = true
                } else {
                    momentaryOpen = false
                }
            }
            if shortOpen, fillStart != nil {
                fill.addLine(to: CGPoint(x: lastX, y: plot.maxY)); fill.closeSubpath()
            }

            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            ctx.stroke(momentaryPath, with: .color(.white.opacity(0.32)),
                       style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            ctx.stroke(shortPath, with: .color(Theme.accent),
                       style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))

            // Integrated
            if integrated.isFinite, integrated > HistoryScale.bottom {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(integrated)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(integrated)))
                ctx.stroke(line, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            }

        }
    }
}
