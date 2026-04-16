import SwiftUI

enum AppSurfaceTone {
    case primary
    case secondary
    case transcript
    case accent(Color)

    fileprivate var fillColor: Color {
        switch self {
        case .primary:
            AppVisualStyle.elevatedPanelBackground
        case .secondary:
            AppVisualStyle.panelBackground
        case .transcript:
            AppVisualStyle.transcriptBackground
        case let .accent(color):
            color.opacity(0.08)
        }
    }

    fileprivate var strokeColor: Color {
        switch self {
        case .primary, .transcript:
            AppVisualStyle.border
        case .secondary:
            AppVisualStyle.secondaryBorder
        case let .accent(color):
            color.opacity(0.2)
        }
    }
}

private struct AppSurfaceModifier: ViewModifier {
    let tone: AppSurfaceTone
    let padding: CGFloat
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                tone.fillColor,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(tone.strokeColor, lineWidth: 1)
            }
    }
}

extension View {
    func appSurface(
        _ tone: AppSurfaceTone = .primary,
        padding: CGFloat = AppVisualStyle.Metrics.surfacePadding,
        cornerRadius: CGFloat = AppVisualStyle.Metrics.surfaceRadius
    ) -> some View {
        modifier(
            AppSurfaceModifier(
                tone: tone,
                padding: padding,
                cornerRadius: cornerRadius
            )
        )
    }
}

struct AppSectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppVisualStyle.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            accessory
        }
    }
}

struct AppMetadataChip: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = AppVisualStyle.secondaryText
    var emphasized = false
    var monospaced = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }

            Text(title)
                .font(monospaced ? .caption2.monospaced() : .caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(backgroundStyle, in: Capsule())
    }

    private var backgroundStyle: some ShapeStyle {
        if emphasized {
            return AnyShapeStyle(tint.opacity(0.14))
        }

        return AnyShapeStyle(AppVisualStyle.panelBackgroundMuted)
    }
}

struct AppInlineNotice: View {
    let title: String
    let detail: String
    var tint: Color = AppVisualStyle.warningTint
    var icon = "exclamationmark.triangle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppVisualStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appSurface(.accent(tint), padding: 12, cornerRadius: 16)
    }
}

struct AppHairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppVisualStyle.secondaryBorder)
            .frame(height: 1)
    }
}
