import SwiftUI
import WaverCore

// MARK: - Readouts

struct BigReadout: View {
    let title: String
    let value: Double
    let target: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(Theme.caption).tracking(0.9)
                .foregroundStyle(Theme.label)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Format.loudness(value))
                    .font(.system(size: 34, weight: .light).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .contentTransition(.identity)
                Text("LUFS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.label)
            }
            DeltaPill(delta: value.isFinite && value > -99 ? value - target : .nan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DeltaPill: View {
    let delta: Double

    var body: some View {
        let color: Color = !delta.isFinite ? Theme.faint
            : abs(delta) <= 1 ? Theme.good
            : delta > 0 ? Theme.warn : Theme.label
        Text(delta.isFinite ? "\(Format.signed(delta)) LU" : "— LU")
            .font(Theme.mono(10, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    var tint: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.7)
                .foregroundStyle(Theme.label)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(Theme.mono(17, .regular))
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.04)))
    }
}

// MARK: - Bar meters

/// Geometry shared by the meter layers. Two identical groups, each a bar pair with its own scale:
/// [L R | dB scale]  gap  [MOM SHORT | LUFS scale]
struct BarLayout {
    static let barWidth: CGFloat = 20
    static let gap: CGFloat = 12
    static let scaleWidth: CGFloat = 30
    /// Space between a bar pair and its scale column.
    static let scaleGap: CGFloat = 8
    /// Space between the peak group and the loudness group.
    static let groupGap: CGFloat = 20
    static var groupWidth: CGFloat { barWidth * 2 + gap }
    static var unitWidth: CGFloat { groupWidth + scaleGap + scaleWidth }

    let size: CGSize
    let top: CGFloat = 16
    var bottom: CGFloat { size.height - 14 }
    var height: CGFloat { bottom - top }
    var peakX: CGFloat { (size.width - (Self.unitWidth * 2 + Self.groupGap)) / 2 }
    var dbScaleX: CGFloat { peakX + Self.groupWidth + Self.scaleGap }
    var loudX: CGFloat { dbScaleX + Self.scaleWidth + Self.groupGap }
    var lufsScaleX: CGFloat { loudX + Self.groupWidth + Self.scaleGap }
    var barXs: [CGFloat] { [peakX, peakX + Self.barWidth + Self.gap, loudX, loudX + Self.barWidth + Self.gap] }

    /// Piecewise scale: −60…−24 gets the bottom quarter, −24…0 the rest.
    static func position(_ db: Double) -> Double {
        let v = min(0, max(-60, db))
        return v < -24 ? (v + 60) / 36 * 0.25 : 0.25 + (v + 24) / 24 * 0.75
    }

    func y(_ db: Double) -> CGFloat { bottom - CGFloat(Self.position(db)) * height }
}

/// Static layer: tracks, ticks, both scales, labels and target marker.
struct BarMetersScale: View {
    let target: Double

    static let barLabels = ["L", "R", "MOM", "S-T"]

    var body: some View {
        Canvas { ctx, size in
            let l = BarLayout(size: size)
            var ticks = Path()
            Self.drawScale(ctx, &ticks, layout: l, size: size, groupX: l.peakX, scaleX: l.dbScaleX, unit: "dB")
            Self.drawScale(ctx, &ticks, layout: l, size: size, groupX: l.loudX, scaleX: l.lufsScaleX, unit: "LUFS")
            ctx.stroke(ticks, with: .color(Theme.grid), lineWidth: 1)

            for (label, x) in zip(Self.barLabels, l.barXs) {
                let track = CGRect(x: x, y: l.top, width: BarLayout.barWidth, height: l.height)
                ctx.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Theme.well))
                ctx.draw(Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(Theme.label),
                         at: CGPoint(x: x + BarLayout.barWidth / 2, y: size.height - 1), anchor: .bottom)
            }

            // Target arrow on the left of the loudness pair, pointing at the bars.
            let ty = l.y(target)
            var marker = Path()
            marker.move(to: CGPoint(x: l.loudX - 4, y: ty))
            marker.addLine(to: CGPoint(x: l.loudX - 9, y: ty - 3.5))
            marker.addLine(to: CGPoint(x: l.loudX - 9, y: ty + 3.5))
            marker.closeSubpath()
            ctx.fill(marker, with: .color(Theme.warn))
        }
    }

    /// Tick lines across one bar pair, numbers in its scale column, and the unit label underneath.
    private static func drawScale(_ ctx: GraphicsContext, _ ticks: inout Path, layout l: BarLayout, size: CGSize,
                                  groupX: CGFloat, scaleX: CGFloat, unit: String) {
        let centerX = scaleX + BarLayout.scaleWidth / 2
        let unitLabelY = size.height - 6.5
        var lastLabelY = -CGFloat.infinity
        for db in [0, -3, -6, -9, -12, -15, -18, -21, -24, -36, -48, -60] {
            let yy = l.y(Double(db))
            ticks.move(to: CGPoint(x: groupX - 3, y: yy))
            ticks.addLine(to: CGPoint(x: groupX + BarLayout.groupWidth + 3, y: yy))
            // Drop labels that would overlap the one above, or the unit label on the bottom row.
            if yy - lastLabelY >= 11 && unitLabelY - yy >= 11 {
                ctx.draw(Text("\(abs(db))").font(Theme.mono(8.5, .medium)).foregroundColor(Theme.faint),
                         at: CGPoint(x: centerX, y: yy), anchor: .center)
                lastLabelY = yy
            }
        }
        ctx.draw(Text(unit).font(.system(size: 9, weight: .bold)).foregroundColor(Theme.label),
                 at: CGPoint(x: centerX, y: size.height - 1), anchor: .bottom)
    }
}

/// Live layer: bar levels and peak-hold lines (60 fps).
struct BarMetersView: View {
    let frame: DisplayFrame
    let target: Double

    var body: some View {
        Canvas { ctx, size in
            let l = BarLayout(size: size)
            let peakGradient = Gradient(stops: [
                .init(color: Theme.good.opacity(0.95), location: 0),
                .init(color: Theme.good, location: BarLayout.position(-9)),
                .init(color: Theme.warn, location: BarLayout.position(-4)),
                .init(color: Theme.warn, location: BarLayout.position(-1.01)),
                .init(color: Theme.hot, location: BarLayout.position(-1)),
                .init(color: Theme.hot, location: 1),
            ])
            let t = BarLayout.position(target)
            let loudGradient = Gradient(stops: [
                .init(color: Theme.accent.opacity(0.75), location: 0),
                .init(color: Theme.accent, location: max(0, t - 0.0001)),
                .init(color: Theme.warn, location: t),
                .init(color: Theme.warn, location: 1),
            ])

            let s = frame.snapshot
            let xs = l.barXs
            let bars: [(CGFloat, Double, Double?, Gradient)] = [
                (xs[0], frame.barL, frame.holdL, peakGradient),
                (xs[1], frame.barR, frame.holdR, peakGradient),
                (xs[2], s.momentary, nil, loudGradient),
                (xs[3], s.shortTerm, nil, loudGradient),
            ]
            let w = BarLayout.barWidth
            var segments = Path()
            for (x, level, hold, gradient) in bars {
                if level.isFinite, level > -60 {
                    let ly = l.y(level)
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: ly, width: w, height: l.bottom - ly), cornerRadius: 2),
                             with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: l.bottom), endPoint: CGPoint(x: 0, y: l.top)))
                    // LED-style segment gaps over the lit part only
                    var yy = l.bottom - 3
                    while yy > ly {
                        segments.addRect(CGRect(x: x, y: yy, width: w, height: 1))
                        yy -= 3
                    }
                }
                if let hold, hold > -60 {
                    ctx.fill(Path(CGRect(x: x, y: l.y(hold) - 1, width: w, height: 2)),
                             with: .color(hold > -1 ? Theme.hot : .white.opacity(0.85)))
                }
            }
            ctx.fill(segments, with: .color(Theme.panel.opacity(0.55)))

            // Target line across the loudness pair (drawn over the bars)
            let ty = l.y(target)
            var marker = Path()
            marker.move(to: CGPoint(x: l.loudX - 4, y: ty))
            marker.addLine(to: CGPoint(x: l.loudX + BarLayout.groupWidth + 4, y: ty))
            ctx.stroke(marker, with: .color(Theme.warn), lineWidth: 1.5)
        }
    }
}

/// Numeric values above each bar, refreshed at a readable rate.
struct BarMetersReadouts: View {
    let frame: DisplayFrame

    var body: some View {
        Canvas { ctx, size in
            let l = BarLayout(size: size)
            let s = frame.snapshot
            let values = [frame.holdL, frame.holdR, s.momentary, s.shortTerm]
            for (x, v) in zip(l.barXs, values) {
                ctx.draw(Text(Format.loudness(v)).font(Theme.mono(9, .medium)).foregroundColor(Theme.text.opacity(0.7)),
                         at: CGPoint(x: x + BarLayout.barWidth / 2, y: 0), anchor: .top)
            }
        }
    }
}
