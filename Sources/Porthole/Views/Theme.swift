import AppKit
import SwiftUI

// MARK: - Palette

extension Color {
    /// A color that resolves to `light` or `dark` depending on the view's appearance.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: NSColor(hex: light), dark: NSColor(hex: dark))
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

/// Porthole's small set of surface colors. Everything else uses system semantic colors,
/// so the app follows the user's accent color and contrast settings.
enum Theme {
    /// Behind the detail pane.
    static let canvas = Color(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// Raised surfaces: cards, diagram nodes, outlined chips.
    static let surface = Color(light: 0xFFFFFF, dark: 0x262628)
    /// Recessed surfaces inside a card: the route diagram's drawing area.
    static let well = Color(light: 0xF4F5F8, dark: 0x1F1F21)
    static let hairline = Color(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.white.withAlphaComponent(0.09))
    /// A firmer edge for cards that sit in a stack and must read as separate items.
    static let outline = Color(light: NSColor.black.withAlphaComponent(0.13), dark: NSColor.white.withAlphaComponent(0.15))
    static let shadow = Color(light: NSColor.black.withAlphaComponent(0.04), dark: NSColor.clear)
    static let nodeShadow = Color(light: NSColor.black.withAlphaComponent(0.08), dark: NSColor.black.withAlphaComponent(0.35))
    /// Porthole's sea green: the SSH tube and lock in the route diagram.
    static let sea = Color(light: 0x0E8C8C, dark: 0x40C9BE)
    static let idle = Color(nsColor: .tertiaryLabelColor)
}

/// A raised, quietly outlined surface.
struct SurfaceBackground: ViewModifier {
    var radius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            // The shadow is cast by the plain background shape. On the whole card it would be
            // recomputed from everything inside (text, the live diagram) whenever any of it changed.
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.shadow, radius: 4, y: 1)
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func surface(radius: CGFloat = 12) -> some View { modifier(SurfaceBackground(radius: radius)) }
}

// MARK: - Light / dark appearance

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return String(localized: "Automatic")
        case .light: return String(localized: "Light")
        case .dark: return String(localized: "Dark")
        }
    }

    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var stored: AppearanceMode {
        UserDefaults.standard.string(forKey: SettingsKey.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
    }

    /// Applies to every window, the menu bar panel and the prompts.
    @MainActor
    func apply() {
        NSApp.appearance = nsAppearance
    }

    /// One click flips between light and dark, starting from whatever is on screen now.
    @MainActor
    var toggled: AppearanceMode {
        switch self {
        case .light: return .dark
        case .dark: return .light
        case .system:
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? .light : .dark
        }
    }
}

/// Toolbar control: click toggles light/dark, the menu offers Automatic too.
struct AppearanceToolbarButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Appearance", systemImage: model.appearance.symbolName)
        } primaryAction: {
            model.toggleAppearance()
        }
        .help("Switch between light and dark. Open the menu to follow the system.")
    }
}

/// Three window thumbnails, like System Settings ▸ Appearance.
struct AppearanceTiles: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppearanceMode.allCases) { mode in
                Button { selection = mode } label: {
                    VStack(spacing: 6) {
                        AppearanceThumbnail(mode: mode)
                            .frame(width: 78, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(selection == mode ? Color.accentColor : Theme.hairline, lineWidth: selection == mode ? 2.5 : 1)
                            )
                        Text(mode.title)
                            .font(.caption)
                            .foregroundStyle(selection == mode ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
    }
}

private struct AppearanceThumbnail: View {
    var mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            ZStack {
                MiniWindow(dark: false)
                MiniWindow(dark: true)
                    .mask(DiagonalHalf())
            }
        }
    }
}

private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// A tiny Porthole window: sidebar, two rows and a route line.
private struct MiniWindow: View {
    var dark: Bool

    var body: some View {
        let bg = dark ? Color(white: 0.11) : Color(white: 0.96)
        let side = dark ? Color(white: 0.17) : Color(white: 0.88)
        let ink = dark ? Color(white: 0.42) : Color(white: 0.72)
        let sea = dark ? Color(nsColor: NSColor(hex: 0x40C9BE)) : Color(nsColor: NSColor(hex: 0x0E8C8C))
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Capsule().fill(sea).frame(width: 16, height: 3)
                Capsule().fill(ink).frame(width: 12, height: 3)
                Capsule().fill(ink).frame(width: 14, height: 3)
            }
            .padding(5)
            .frame(width: 26)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(side)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink).frame(width: 24, height: 3)
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1.5).fill(side).frame(width: 9, height: 12)
                    Rectangle().fill(sea).frame(height: 1.5)
                    RoundedRectangle(cornerRadius: 1.5).fill(side).frame(width: 9, height: 12)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(bg)
    }
}
