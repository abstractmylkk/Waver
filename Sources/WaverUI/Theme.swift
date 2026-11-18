import SwiftUI

public enum Theme {
    public static let background = Color(red: 0.067, green: 0.071, blue: 0.078)
    static let panel = Color(red: 0.098, green: 0.102, blue: 0.114)
    static let well = Color(red: 0.055, green: 0.058, blue: 0.065)
    static let stroke = Color.white.opacity(0.07)
    static let grid = Color.white.opacity(0.055)
    static let gridStrong = Color.white.opacity(0.11)
    static let label = Color.white.opacity(0.45)
    static let faint = Color.white.opacity(0.28)
    static let text = Color.white.opacity(0.92)

    public static let accent = Color(red: 0.36, green: 0.74, blue: 1.0)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.52)
    static let warn = Color(red: 1.0, green: 0.74, blue: 0.27)
    static let hot = Color(red: 1.0, green: 0.33, blue: 0.30)

    // Waveform band colours (low / mid / high)
    static let bandLow = SIMD3<Double>(1.00, 0.33, 0.28)
    static let bandMid = SIMD3<Double>(0.98, 0.80, 0.30)
    static let bandHigh = SIMD3<Double>(0.33, 0.70, 1.00)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    static let caption = Font.system(size: 9.5, weight: .semibold)
}

/// Rounded surface used for every module.
struct Panel<Content: View, Accessory: View>: View {
    var title: String?
    /// Control shown right after the title (left side of the header).
    var titleAccessory: AnyView?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil,
         titleAccessory: AnyView? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.titleAccessory = titleAccessory
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 6) {
                    Text(title.uppercased())
                        .font(Theme.caption)
                        .tracking(0.9)
                        .foregroundStyle(Theme.label)
                    if let titleAccessory {
                        titleAccessory.padding(.leading, 4)
                    }
                    Spacer(minLength: 4)
                    accessory()
                }
                .frame(height: 14)
            }
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.panel)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 1)
        )
    }
}

enum Format {
    static func loudness(_ v: Double) -> String {
        guard v.isFinite, v > -99 else { return "—" }
        return String(format: "%.1f", v)
    }

    static func signed(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%+.1f", v)
    }

    static func lu(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        return String(format: "%.1f", v)
    }
}
