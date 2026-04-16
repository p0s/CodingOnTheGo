import SwiftUI

struct AdaptiveGlassCluster<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(
        spacing: CGFloat = 16,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let tint: Color
    let cornerRadius: CGFloat
    let padding: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content
                .padding(padding)
                .glassEffect(
                    .regular.tint(tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppVisualStyle.border, lineWidth: 1)
                }
        } else {
            content
                .padding(padding)
                .background(
                    fallbackBackground,
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppVisualStyle.secondaryBorder, lineWidth: 1)
                }
        }
    }

    private var fallbackBackground: some ShapeStyle {
        reduceTransparency
            ? AnyShapeStyle(AppVisualStyle.panelBackground)
            : AnyShapeStyle(AppVisualStyle.panelBackground.opacity(0.92))
    }
}

extension View {
    func adaptiveGlassSurface(
        tint: Color = Color.white.opacity(0.12),
        cornerRadius: CGFloat = 24,
        padding: CGFloat = AppVisualStyle.Metrics.surfacePadding
    ) -> some View {
        modifier(
            AdaptiveGlassSurfaceModifier(
                tint: tint,
                cornerRadius: cornerRadius,
                padding: padding
            )
        )
    }
}
