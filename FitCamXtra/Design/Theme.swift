import SwiftUI

// Design tokens from the FitCamXtra handoff. Warm-black "evidence" palette,
// a single Dutch-orange action colour, red reserved for record and destructive.

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}

enum Palette {
    static let bg = Color(hex: 0x131210)
    static let surface = Color(hex: 0x1B1916)

    static let hairline = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.06)

    static let ink = Color(hex: 0xEFE8DC)
    static let inkSecondary = Color(hex: 0xEFE8DC, alpha: 0.72)
    static let inkTertiary = Color(hex: 0xEFE8DC, alpha: 0.62)
    // Small type on a near-black ground needs real contrast: these were
    // 0.45 and 0.38, which measure 3.9:1 and 3.2:1 and fail WCAG AA.
    static let inkQuaternary = Color(hex: 0xEFE8DC, alpha: 0.60)
    static let inkFaint = Color(hex: 0xEFE8DC, alpha: 0.52)
    /// Captions over video, where the ground is not the app background.
    static let onVideoCaption = Color.white.opacity(0.62)

    static let accent = Color(hex: 0xFF5C00)
    static let accentText = Color(hex: 0xFF8A3D)
    static let accentInk = Color(hex: 0x1A0B04)

    static let record = Color(hex: 0xE8351B)
    static let destructiveText = Color(hex: 0xFF7A66)
    static let destructiveBg = Color(hex: 0xE83514, alpha: 0.16)

    /// Camera-imagery placeholder stripes. Replaced by the RTSP surface and real thumbnails.
    static let placeholderLight = Color(hex: 0x25211C)
    static let placeholderDark = Color(hex: 0x1E1B17)

    static let glass = Color(hex: 0x131210, alpha: 0.62)
    static let glassBorder = Color.white.opacity(0.12)
}

enum Typo {
    /// Flip to true once IBM Plex is bundled in Resources. Until then the SF
    /// pair keeps the sans/mono split the design depends on.
    static let useBundledPlex = false

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if useBundledPlex {
            return .custom(plexSansName(for: weight), fixedSize: size)
        }
        return .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if useBundledPlex {
            return .custom(plexMonoName(for: weight), fixedSize: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
    }

    private static func plexSansName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "IBMPlexSans-Bold"
        case .semibold: return "IBMPlexSans-SemiBold"
        case .medium: return "IBMPlexSans-Medium"
        default: return "IBMPlexSans"
        }
    }

    private static func plexMonoName(for weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black, .semibold: return "IBMPlexMono-SemiBold"
        case .medium: return "IBMPlexMono-Medium"
        default: return "IBMPlexMono"
        }
    }
}

enum Metrics {
    static let gutter: CGFloat = 18
    static let overlayGutter: CGFloat = 20
    /// Scroll bottom padding that clears the tab bar.
    static let scrollBottom: CGFloat = 96
    static let headerTop: CGFloat = 62

    enum Radius {
        static let badge: CGFloat = 3
        static let tile: CGFloat = 4
        static let small: CGFloat = 5
        static let card: CGFloat = 6
        static let bar: CGFloat = 8
        static let pill: CGFloat = 100
    }
}

// MARK: - Shared chrome

/// Uppercase mono eyebrow used above every group and strip.
struct Eyebrow: View {
    let text: String
    var color: Color = Palette.inkFaint
    var size: CGFloat = 11
    var tracking: CGFloat = 0.88

    var body: some View {
        Text(text.uppercased())
            .font(Typo.mono(size, .semibold))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}

/// The blurred glass treatment used for chips and the live control bar.
struct GlassBackground: ViewModifier {
    var radius: CGFloat = Metrics.Radius.pill
    var blur: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Palette.glass, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Palette.glassBorder, lineWidth: 1)
            )
    }
}

extension View {
    func glass(radius: CGFloat = Metrics.Radius.pill) -> some View {
        modifier(GlassBackground(radius: radius))
    }

    /// Card surface: warm-black fill with a 1px hairline.
    func cardSurface(radius: CGFloat = Metrics.Radius.card, border: Color = Palette.hairline) -> some View {
        self
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}

/// Diagonal-striped stand-in for camera imagery. Deliberate placeholder:
/// replaced by the RTSP surface and real thumbnails.
struct CameraPlaceholder: View {
    var caption: String?
    var subcaption: String?

    var body: some View {
        ZStack {
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.placeholderDark))
                let step: CGFloat = 28
                let span = size.width + size.height
                var x = -size.height
                while x < span {
                    var bar = Path()
                    bar.move(to: CGPoint(x: x, y: 0))
                    bar.addLine(to: CGPoint(x: x + 14, y: 0))
                    bar.addLine(to: CGPoint(x: x + 14 - size.height, y: size.height))
                    bar.addLine(to: CGPoint(x: x - size.height, y: size.height))
                    bar.closeSubpath()
                    context.fill(bar, with: .color(Palette.placeholderLight))
                    x += step
                }
            }

            if caption != nil || subcaption != nil {
                VStack(spacing: 3) {
                    if let caption {
                        Text(caption)
                            .font(Typo.mono(10.5))
                            .foregroundStyle(Palette.onVideoCaption)
                    }
                    if let subcaption {
                        Text(subcaption)
                            .font(Typo.mono(10.5))
                            .foregroundStyle(Palette.onVideoCaption)
                    }
                }
                .multilineTextAlignment(.center)
            }
        }
        .clipped()
    }
}
