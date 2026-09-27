import SwiftUI

/// Shared style kit: big type, pill buttons, generous spacing.
enum Theme {
    static let ink = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let inkMuted = Color(red: 0.39, green: 0.45, blue: 0.55)
    static let brand = Color(red: 0.49, green: 0.23, blue: 0.93)
    static let brandSoft = Color(red: 0.93, green: 0.91, blue: 1.0)
    static let green = Color(red: 0.09, green: 0.64, blue: 0.29)
    static let greenSoft = Color(red: 0.86, green: 0.99, blue: 0.91)
}

struct ScreenHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.ink)
            if let subtitle {
                Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PillButtonStyle: ButtonStyle {
    var background: Color = Theme.brand
    var foreground: Color = .white
    var outlined = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(outlined ? Color.clear : background, in: Capsule())
            .overlay(Capsule().stroke(outlined ? Theme.inkMuted.opacity(0.5) : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var softPill: PillButtonStyle { PillButtonStyle(background: Theme.brandSoft, foreground: Theme.brand) }
    static var outlinePill: PillButtonStyle { PillButtonStyle(foreground: Theme.ink, outlined: true) }
}

/// Standard situation-screen scaffold: scrolling column, 24pt padding, 12pt spacing.
struct ScreenColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}
