import SwiftUI
import AppKit
import CoreImage

/// Animated "out-of-focus photograph" backdrop for the dark hero banners.
///
/// Instead of shipping stock imagery (the literal Wispr Flow approach), the soft
/// cinematic feel is built procedurally: a few large, heavily-blurred colour
/// blobs drift slowly over the base gradient, finished with film grain and a
/// vignette. `FlowHeroSurface` wraps any hero content with this backdrop and
/// adds a restrained parallax / tilt reaction on hover.
struct FlowAuroraBackground: View {
    /// Cursor position over the banner, normalised to -1...1 (centre = 0).
    /// Layers shift by their own `depth`, giving a parallax sense of depth.
    var parallax: CGSize = .zero

    /// True only while the hosting window is actually on screen. The animated
    /// backdrop is a 30 fps MeshGradient — left running it burns ~20% CPU forever,
    /// even when the window is closed/hidden (SwiftUI keeps the TimelineView ticking
    /// for a cached, off-screen window). Gating on real occlusion freezes it when
    /// nobody can see it.
    @State private var onScreen = true

    var body: some View {
        ZStack {
            // Base glow: an animated MeshGradient on macOS 15+ (richer, more
            // liquid), falling back to drifting blurred blobs on macOS 13–14.
            if #available(macOS 15.0, *) {
                MeshAurora(parallax: parallax, animating: onScreen)
            } else {
                LegacyAurora(parallax: parallax)
            }

            // Film grain — tiled monochrome noise, barely there.
            if let grain = FlowGrain.image {
                grain
                    .resizable(resizingMode: .tile)
                    .opacity(0.05)
                    .blendMode(.overlay)
                    .allowsHitTesting(false)
            }

            // Vignette to seat the glow and add depth.
            RadialGradient(colors: [.clear, .black.opacity(0.28)],
                           center: .center, startRadius: 70, endRadius: 360)
                .allowsHitTesting(false)
        }
        .clipped()
        .background(WindowVisibilityObserver { visible in
            if onScreen != visible { onScreen = visible }
        })
    }
}

/// Reports whether the hosting `NSWindow` is currently on screen
/// (`occlusionState` contains `.visible`). Lets animated backdrops pause their
/// per-frame work when the window is closed, hidden (Cmd-H), minimised or fully
/// occluded — otherwise a `TimelineView(.animation)` keeps firing (and burning
/// CPU/GPU) indefinitely even when nothing is visible.
struct WindowVisibilityObserver: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Tracker(onChange: onChange) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Tracker)?.onChange = onChange
    }

    final class Tracker: NSView {
        var onChange: (Bool) -> Void
        private var token: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let token { NotificationCenter.default.removeObserver(token); self.token = nil }
            guard let window else { report(false); return }
            report(window.occlusionState.contains(.visible))
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                guard let self, let w = self.window else { return }
                self.report(w.occlusionState.contains(.visible))
            }
        }

        // Hop off the current update pass so we never mutate SwiftUI state mid-layout.
        private func report(_ visible: Bool) {
            DispatchQueue.main.async { [onChange] in onChange(visible) }
        }

        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}

/// MeshGradient backdrop (macOS 15+). A 3×3 mesh whose left column stays dark so
/// the left-aligned copy keeps contrast, with teal weighted right and a muted
/// warm note bottom-centre. Interior points drift on a TimelineView clock and
/// nudge with the parallax cursor; corners stay pinned so the mesh never gaps.
@available(macOS 15.0, *)
private struct MeshAurora: View {
    var parallax: CGSize
    /// Drives the per-frame clock only while the window is on screen; otherwise we
    /// render a single frozen frame so the mesh costs nothing in the background.
    var animating: Bool = true

    // Dark column 0 (left) stays put so the copy keeps contrast.
    private let dark0 = Color(red: 0.150, green: 0.135, blue: 0.120)
    private let dark1 = Color(red: 0.150, green: 0.140, blue: 0.125)
    private let dark2 = Color(red: 0.180, green: 0.165, blue: 0.140)
    private let green = Color(red: 0.215, green: 0.335, blue: 0.285)

    var body: some View {
        if animating {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                MeshGradient(width: 3, height: 3, points: points(t), colors: colors(t))
            }
        } else {
            // Frozen frame — no TimelineView clock, no per-frame mesh recompute.
            MeshGradient(width: 3, height: 3, points: points(0), colors: colors(0))
        }
    }

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        let px = Float(parallax.width) * 0.06
        let py = Float(parallax.height) * 0.06
        func osc(_ speed: Double, _ phase: Double, _ amp: Float) -> Float {
            Float(sin(t * speed + phase)) * amp
        }
        return [
            SIMD2(0, 0),
            SIMD2(0.5 + osc(0.46, 0, 0.13) + px, 0),                       // top-mid (x only)
            SIMD2(1, 0),
            SIMD2(0, 0.5 + osc(0.40, 1, 0.13) + py),                       // mid-left (y only)
            SIMD2(0.5 + osc(0.55, 2, 0.18) + px, 0.5 + osc(0.45, 3, 0.18) + py), // centre
            SIMD2(1, 0.5 + osc(0.49, 4, 0.14) + py),                       // mid-right (y only)
            SIMD2(0, 1),
            SIMD2(0.5 + osc(0.52, 5, 0.13) + px, 1),                       // bot-mid (x only)
            SIMD2(1, 1),
        ]
    }

    /// Colours breathe between two shades so the field reads as alive, not just
    /// shifting. Left column stays dark for legibility.
    private func colors(_ t: TimeInterval) -> [Color] {
        let f = sin(t * 0.32) * 0.5 + 0.5
        let g = sin(t * 0.42 + 1.1) * 0.5 + 0.5
        let tealBright = lerp((0.160, 0.560, 0.470), (0.270, 0.760, 0.620), g)
        let teal      = lerp((0.120, 0.470, 0.395), (0.210, 0.660, 0.545), f)
        let warm      = lerp((0.380, 0.290, 0.200), (0.560, 0.405, 0.255), g)
        return [
            dark0, dark1, tealBright,  // top
            dark1, green, teal,        // mid
            dark2, warm, teal,         // bottom
        ]
    }

    private func lerp(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ f: Double) -> Color {
        Color(red: a.0 + (b.0 - a.0) * f,
              green: a.1 + (b.1 - a.1) * f,
              blue: a.2 + (b.2 - a.2) * f)
    }
}

/// Fallback backdrop (macOS 13–14): drifting, heavily-blurred colour blobs over
/// the base gradient.
private struct LegacyAurora: View {
    var parallax: CGSize

    var body: some View {
        ZStack {
            FlowTheme.heroGradient

            // Teal glow, weighted to the right so the (left-aligned) copy stays clean.
            AuroraBlob(color: Color(red: 0.16, green: 0.64, blue: 0.53).opacity(0.55),
                       size: 340, from: CGPoint(x: 175, y: -45), to: CGPoint(x: 235, y: 20),
                       duration: 9, depth: 22, parallax: parallax)

            // Warm amber — the "film" warmth, low and to the right.
            AuroraBlob(color: Color(red: 0.86, green: 0.55, blue: 0.34).opacity(0.28),
                       size: 300, from: CGPoint(x: 120, y: 70), to: CGPoint(x: 55, y: 40),
                       duration: 11, depth: 14, parallax: parallax)

            // Deep green ambience drifting through the centre.
            AuroraBlob(color: Color(red: 0.22, green: 0.34, blue: 0.29).opacity(0.5),
                       size: 380, from: CGPoint(x: -30, y: -30), to: CGPoint(x: 25, y: -70),
                       duration: 13, depth: 9, parallax: parallax)
        }
    }
}

/// A single soft light source: a radial-gradient circle that slowly oscillates
/// between two points (autoreversing, with a per-blob duration so the set never
/// visibly loops) and shifts with the parallax cursor offset.
private struct AuroraBlob: View {
    let color: Color
    let size: CGFloat
    let from: CGPoint
    let to: CGPoint
    let duration: Double
    let depth: CGFloat
    let parallax: CGSize

    @State private var drifted = false

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: size / 2))
            .frame(width: size, height: size)
            .offset(x: drifted ? to.x : from.x, y: drifted ? to.y : from.y)
            .offset(x: parallax.width * depth, y: parallax.height * depth)
            .blur(radius: size * 0.16)
            .onAppear {
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    drifted = true
                }
            }
    }
}

/// Wraps hero content with the animated aurora backdrop and a subtle hover
/// reaction: layers parallax inward, the whole card tilts toward the cursor and
/// lifts slightly. Restrained by design — small angles, soft spring.
struct FlowHeroSurface<Content: View>: View {
    var cornerRadius: CGFloat = FlowTheme.cornerRadius
    @ViewBuilder var content: () -> Content

    @State private var hover: CGSize = .zero
    @State private var hovering = false
    @State private var size: CGSize = .zero

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content()
            .background(FlowAuroraBackground(parallax: hover))
            .clipShape(shape)
            .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
            .background(GeometryReader { g in
                Color.clear.preference(key: HeroSizeKey.self, value: g.size)
            })
            .onPreferenceChange(HeroSizeKey.self) { size = $0 }
            .rotation3DEffect(.degrees(Double(hover.width) * 3), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .rotation3DEffect(.degrees(Double(-hover.height) * 3), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            .scaleEffect(hovering ? 1.01 : 1.0)
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.12),
                    radius: hovering ? 18 : 8, y: hovering ? 10 : 4)
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: hover)
            .animation(.easeOut(duration: 0.3), value: hovering)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hovering = true
                    guard size.width > 0, size.height > 0 else { return }
                    hover = CGSize(width: (p.x / size.width) * 2 - 1,
                                   height: (p.y / size.height) * 2 - 1)
                case .ended:
                    hovering = false
                    hover = .zero
                }
            }
    }
}

private struct HeroSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// Lazily-built, cached tiling grain texture (monochrome random noise).
private enum FlowGrain {
    static let image: Image? = make()

    private static func make() -> Image? {
        let context = CIContext(options: nil)
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let mono = noise.applyingFilter("CIColorControls",
                                        parameters: [kCIInputSaturationKey: 0,
                                                     kCIInputContrastKey: 1.2])
        let rect = CGRect(x: 0, y: 0, width: 160, height: 160)
        guard let cg = context.createCGImage(mono.cropped(to: rect), from: rect) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}
