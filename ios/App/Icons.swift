import SwiftUI

/// The product's real icons, so an agent or a phase is identified the same way it is on the web.
///
/// Two kinds, because the web app has two kinds:
///
/// * **ChatGPT, Claude, NotebookLM** are brand PNGs, copied out of `dg-research/public/icons/` and
///   bundled here. Redrawing a brand mark by hand would produce a near-miss, which is worse than a
///   letter placeholder — a near-miss looks like the real thing and isn't.
/// * **Gemini, Brief, YouTube** are vector, ported from the frontend's inline SVG with the same
///   geometry and the same gradient stops.
///
/// Letters in circles were the placeholder before this, and they made every agent look like the same
/// component with a different character in it.
struct AgentIcon: View {
    let id: String
    var size: CGFloat = 22

    var body: some View {
        switch id {
        case "chatgpt", "claude", "notebooklm":
            BundledIcon(name: id, size: size)
        case "gemini":
            GeminiMark(size: size)
        case "brief":
            BriefMark(size: size)
        case "youtube":
            YouTubeMark(size: size)
        default:
            // A visible, honest fallback rather than an empty space, so an unknown id is obvious in
            // review instead of silently rendering nothing.
            RoundedRectangle(cornerRadius: size * 0.2)
                .fill(DS.C.surfaceHigh)
                .frame(width: size, height: size)
                .overlay(
                    Text("?").font(DS.F.mono(size * 0.5, .bold))
                        .foregroundStyle(DS.C.textTertiary)
                )
        }
    }
}

/// A PNG loaded from the app bundle.
///
/// Loaded by path rather than `UIImage(named:)` because this app has no asset catalog — the bundle is
/// assembled by `bin/build_app.sh`, and loose resources are what it copies in.
private struct BundledIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // States the failure rather than hiding it: a missing icon means the build script did
                // not copy Assets/, and a blank square would look like a design choice.
                RoundedRectangle(cornerRadius: size * 0.2).fill(DS.C.surfaceHigh)
            }
        }
        .frame(width: size, height: size)
        // 4pt at 20pt in the web app's `rounded-[4px]`, scaled so it holds at any size.
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

/// Gemini's four-pointed star, with the frontend's exact three-stop gradient.
///
/// Path and viewBox transcribed from `GeminiIcon`: `M14 2C15.5 9 19 12.5 26 14C19 15.5 15.5 19 14 26C12.5 19 9 15.5 2 14C9 12.5 12.5 9 14 2Z`
/// on a 28×28 box, filled `#1A73E8 → #8E75B2 → #D93025` top-left to bottom-right.
private struct GeminiMark: View {
    let size: CGFloat

    var body: some View {
        StarPath()
            .fill(
                LinearGradient(
                    colors: [
                        Color(hex: 0x1A73E8), Color(hex: 0x8E75B2), Color(hex: 0xD93025),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
    }

    /// The star, in a 28×28 space scaled to the requested size.
    private struct StarPath: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / 28
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
            }
            var path = Path()
            path.move(to: p(14, 2))
            path.addCurve(to: p(26, 14), control1: p(15.5, 9), control2: p(19, 12.5))
            path.addCurve(to: p(14, 26), control1: p(19, 15.5), control2: p(15.5, 19))
            path.addCurve(to: p(2, 14), control1: p(12.5, 19), control2: p(9, 15.5))
            path.addCurve(to: p(14, 2), control1: p(9, 12.5), control2: p(12.5, 9))
            path.closeSubpath()
            return path
        }
    }
}

/// The Brief icon: a clipboard with ruled lines and a sparkle, ported from `BriefIcon`'s 24×24 SVG.
private struct BriefMark: View {
    let size: CGFloat
    private var blue: Color { Color(hex: 0x3B82F6) }
    private var indigo: Color { Color(hex: 0x6366F1) }

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height) / 24
            ZStack(alignment: .topLeading) {
                // Body
                RoundedRectangle(cornerRadius: 2.5 * s)
                    .fill(blue.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2.5 * s)
                            .stroke(blue, lineWidth: 1.5 * s)
                    )
                    .frame(width: 16 * s, height: 18 * s)
                    .offset(x: 4 * s, y: 3 * s)
                // Clip at the top
                RoundedRectangle(cornerRadius: 1.5 * s)
                    .fill(blue.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5 * s)
                            .stroke(blue, lineWidth: 1.2 * s)
                    )
                    .frame(width: 8 * s, height: 4 * s)
                    .offset(x: 8 * s, y: 1 * s)
                // Ruled lines, fading as they shorten — the SVG's 1.0 / 0.7 / 0.5 opacities.
                line(from: 8, to: 16, y: 10, opacity: 1, s: s)
                line(from: 8, to: 14, y: 13.5, opacity: 0.7, s: s)
                line(from: 8, to: 11, y: 17, opacity: 0.5, s: s)
                // Sparkle
                Circle()
                    .fill(indigo.opacity(0.7))
                    .frame(width: 2 * s, height: 2 * s)
                    .offset(x: 16.5 * s, y: 4.5 * s)
            }
        }
        .frame(width: size, height: size)
    }

    private func line(
        from x1: CGFloat, to x2: CGFloat, y: CGFloat, opacity: Double, s: CGFloat
    ) -> some View {
        Capsule()
            .fill(blue.opacity(opacity))
            .frame(width: (x2 - x1) * s, height: 1.3 * s)
            .offset(x: x1 * s, y: (y - 0.65) * s)
    }
}

/// YouTube's rounded rect with a play triangle.
private struct YouTubeMark: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(DS.C.youtube)
            .frame(width: size, height: size * 0.72)
            .overlay(
                Triangle()
                    .fill(.white)
                    .frame(width: size * 0.22, height: size * 0.26)
            )
            .frame(width: size, height: size)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
