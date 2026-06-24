import SwiftUI
import AppKit

/// Visual system for the main window, mirroring the warm-paper / serif-display
/// aesthetic of the reference design: off-white background, soft cards, teal
/// accent, dark photographic-style hero banners. Colors are *dynamic* (light /
/// dark pairs) so the whole window — including the embedded settings Forms —
/// follows the user's theme choice (see ThemeManager), which drives the
/// NSWindow appearance.
enum FlowTheme {
    /// Build a color that resolves differently for light vs dark appearance.
    private static func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    // Surfaces
    static let paper       = dyn((0.957, 0.945, 0.925), (0.118, 0.114, 0.110))
    static let card        = dyn((1.000, 1.000, 1.000), (0.165, 0.161, 0.157))
    static let cardStroke  = dyn((0.910, 0.894, 0.863), (0.262, 0.255, 0.247))
    static let rowSelected = dyn((0.902, 0.886, 0.851), (0.247, 0.239, 0.231))
    static let rowHover    = dyn((0.933, 0.922, 0.898), (0.204, 0.200, 0.196))

    // Text
    static let ink          = dyn((0.122, 0.106, 0.086), (0.945, 0.937, 0.925))
    static let inkSecondary = dyn((0.420, 0.400, 0.360), (0.627, 0.616, 0.600))

    // Accent (teal) — slightly brighter in dark for contrast.
    static let accent     = dyn((0.075, 0.478, 0.404), (0.180, 0.616, 0.522))
    static let accentSoft = accent.opacity(0.14)

    // Hero (dark banner) gradient — dark in both themes by design.
    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.157, green: 0.137, blue: 0.122),
            Color(red: 0.227, green: 0.267, blue: 0.239),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let cornerRadius: CGFloat = 16
}

/// Tracks the user's light/dark choice and pushes it onto the app's windows by
/// switching their NSAppearance. Dynamic FlowTheme colors + system controls
/// (the settings Forms) then resolve to the chosen theme automatically.
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published var isDark: Bool {
        didSet {
            UserDefaults.standard.set(isDark, forKey: "lf.darkMode")
            applyToWindows()
        }
    }

    private init() {
        // Dark is the default identity; honor a saved preference if present.
        if UserDefaults.standard.object(forKey: "lf.darkMode") == nil {
            isDark = true
        } else {
            isDark = UserDefaults.standard.bool(forKey: "lf.darkMode")
        }
    }

    var appearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    func applyToWindows() {
        let appearance = self.appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

/// Serif display text, used for big headings ("Welcome back", hero titles,
/// section titles) to match the reference's transitional-serif look.
struct DisplayText: View {
    let text: String
    var size: CGFloat = 28
    var weight: Font.Weight = .semibold
    var italic: Bool = false
    var color: Color = FlowTheme.ink

    init(_ text: String, size: CGFloat = 28, weight: Font.Weight = .semibold, italic: Bool = false, color: Color = FlowTheme.ink) {
        self.text = text
        self.size = size
        self.weight = weight
        self.italic = italic
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .serif))
            .italic(italic)
            .foregroundColor(color)
    }
}

/// White rounded card with a subtle warm stroke — the building block for all
/// content panels.
struct FlowCard<Content: View>: View {
    var padding: CGFloat = 20
    var minHeight: CGFloat? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: minHeight ?? 0, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                    .fill(FlowTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                    .stroke(FlowTheme.cardStroke, lineWidth: 1)
            )
    }
}

/// Dark hero banner with a serif title (one word optionally italicised), a
/// subtitle, and an optional light CTA button.
struct FlowHero: View {
    let titleLeading: String
    var titleEmphasis: String = ""
    var titleTrailing: String = ""
    let subtitle: String
    var ctaTitle: String?
    var ctaAction: (() -> Void)?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: FlowTheme.cornerRadius, style: .continuous)
                .fill(FlowTheme.heroGradient)

            VStack(alignment: .leading, spacing: 12) {
                (
                    Text(titleLeading)
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                    + Text(titleEmphasis.isEmpty ? "" : " \(titleEmphasis)")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .italic()
                    + Text(titleTrailing.isEmpty ? "" : " \(titleTrailing)")
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                )
                .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                if let ctaTitle, let ctaAction {
                    Button(action: ctaAction) {
                        Text(ctaTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(FlowTheme.ink)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().fill(FlowTheme.paper)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 150)
    }
}

/// Small uppercase section label, e.g. "TODAY".
struct FlowSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(FlowTheme.inkSecondary)
    }
}

// MARK: - Settings building blocks

/// A titled settings group: optional label above a Flow card holding rows.
struct FlowSettingsGroup<Content: View>: View {
    var title: String?
    var spacing: CGFloat = 14
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, spacing: CGFloat = 14, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FlowTheme.ink)
            }
            FlowCard(padding: 18) {
                VStack(alignment: .leading, spacing: spacing, content: content)
            }
        }
    }
}

/// Label (+ optional detail) with a trailing switch tinted with the accent.
struct FlowToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundColor(FlowTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(FlowTheme.accent)
        }
    }
}

/// Label (+ optional detail) with a trailing menu-style picker. `options` is a
/// list of (value, label) pairs so callers can map enums/strings inline.
struct FlowPickerRow<T: Hashable>: View {
    let title: String
    var detail: String?
    @Binding var selection: T
    let options: [(value: T, label: String)]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundColor(FlowTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(FlowTheme.ink)
            .fixedSize()
        }
    }
}

/// Status row for a system permission, with an "Open System Settings" action.
struct FlowPermissionRow: View {
    let title: String
    let granted: Bool
    var detail: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(granted ? FlowTheme.accent : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundColor(FlowTheme.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(FlowTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            FlowSmallButton(title: "Open System Settings", action: action)
        }
    }
}

/// Compact bordered button matching the light surface (used in settings rows).
struct FlowSmallButton: View {
    let title: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(prominent ? .white : FlowTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(prominent ? FlowTheme.accent : (hovering ? FlowTheme.rowSelected : FlowTheme.paper))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(prominent ? .clear : FlowTheme.cardStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Plain text field on a light bordered surface, for settings inputs.
struct FlowTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(FlowTheme.paper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(FlowTheme.cardStroke, lineWidth: 1)
            )
    }
}
