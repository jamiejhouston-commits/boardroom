import SwiftUI
import UIKit

/// The Hermes visual system — one source of truth for color.
///
/// Deliberately muted and premium:
///  • Light mode  → creamy off-white canvas, emerald + navy + silver accents.
///  • Dark mode   → deep navy-charcoal canvas, same accents tuned for contrast.
///  • Brand mark  → antique (not bright) gold.
///
/// No neon, no glow. If a color ever needs tuning, change it HERE only.
enum HermesTheme {

    // MARK: Brand / accent — constant across modes (chosen to read on cream *and* navy)

    /// Primary action color — buttons, key outlines, "online" status.
    static let emerald = Color(hex: "1C7A55")
    /// Lighter emerald for fills/highlights.
    static let emeraldSoft = Color(hex: "2E9B72")
    /// Navy — secondary outlines, headers.
    static let navy = Color(hex: "23426B")
    /// A calmer mid blue for variety.
    static let steel = Color(hex: "3C6FA0")
    /// Sleek silver — hairlines, idle states, chrome.
    static let silver = Color(hex: "AEB6BE")
    /// Antique gold — the Hermes brand mark only (not a UI accent).
    static let gold = Color(hex: "C7A35A")

    // MARK: Adaptive surfaces

    /// App canvas.
    static let background = dynamic(
        light: (0.961, 0.945, 0.910),   // creamy off-white
        dark:  (0.051, 0.063, 0.090)    // deep navy-charcoal
    )

    /// Card / panel surface.
    static let surface = dynamic(
        light: (0.992, 0.984, 0.964),
        dark:  (0.086, 0.102, 0.137)
    )

    /// Slightly raised surface (hero, emphasized cards).
    static let surfaceRaised = dynamic(
        light: (1.000, 0.996, 0.984),
        dark:  (0.117, 0.137, 0.180)
    )

    /// Hairline borders — navy-tinted in light, silver-tinted in dark.
    static let hairline = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.68, green: 0.72, blue: 0.78, alpha: 0.18)
            : UIColor(red: 0.14, green: 0.26, blue: 0.42, alpha: 0.16)
    })

    /// Primary text.
    static let textPrimary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
            : UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)
    })

    /// Secondary / muted text.
    static let textSecondary = Color(uiColor: UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.67, blue: 0.74, alpha: 1)
            : UIColor(red: 0.34, green: 0.39, blue: 0.45, alpha: 1)
    })

    // MARK: Helper

    /// Build an RGB color that swaps between light and dark automatically.
    private static func dynamic(light: (Double, Double, Double),
                                dark: (Double, Double, Double)) -> Color {
        Color(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

// MARK: - Card container

/// Standard Hermes card: muted surface + hairline outline, no glow.
private struct HermesCard: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(HermesTheme.hairline, lineWidth: 1)
            )
    }
}

extension View {
    /// Wrap content in the standard muted Hermes card.
    func hermesCard(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        modifier(HermesCard(padding: padding, radius: radius))
    }
}
