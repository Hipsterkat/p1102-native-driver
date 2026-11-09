import SwiftUI

/// Liquid Glass on macOS 26 and later, standard materials before that.
extension View {
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 20) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Fades content that scrolls up under the window buttons (macOS 26+).
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    @ViewBuilder
    func translucentWindowBackground() -> some View {
        if #available(macOS 15, *) {
            containerBackground(.ultraThinMaterial, for: .window)
        } else {
            background(.ultraThinMaterial)
        }
    }
}

/// Groups glass shapes so they blend and refract together (macOS 26+).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A titled section on a glass card.
struct Card<Content: View>: View {
    var title: String?
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary) }
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface()
    }
}
