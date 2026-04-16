import SwiftUI

enum AppVisualStyle {
    static let shellTop = Color(uiColor: .systemGroupedBackground)
    static let shellBottom = Color(uiColor: .secondarySystemGroupedBackground)
    static let transcriptBackground = Color(uiColor: .systemBackground)
    static let panelBackground = Color(uiColor: .secondarySystemBackground)
    static let panelBackgroundMuted = Color(uiColor: .tertiarySystemBackground)
    static let elevatedPanelBackground = Color(uiColor: .systemBackground)
    static let chromeTint = Color.accentColor.opacity(0.08)
    static let border = Color.primary.opacity(0.08)
    static let secondaryBorder = Color.primary.opacity(0.05)
    static let strongBorder = Color.primary.opacity(0.12)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let assistantBubble = Color(uiColor: .secondarySystemBackground)
    static let userBubble = Color.accentColor.opacity(0.11)
    static let systemBubble = Color.orange.opacity(0.10)
    static let successTint = Color.green
    static let warningTint = Color.orange
    static let dangerTint = Color.red

    enum Metrics {
        static let pageSpacing: CGFloat = 14
        static let sectionSpacing: CGFloat = 12
        static let surfacePadding: CGFloat = 14
        static let compactSurfacePadding: CGFloat = 12
        static let surfaceRadius: CGFloat = 20
        static let chipRadius: CGFloat = 12
    }
}

var shellBackground: some View {
    LinearGradient(
        colors: [
            AppVisualStyle.shellTop,
            AppVisualStyle.shellBottom,
            AppVisualStyle.panelBackgroundMuted.opacity(0.55),
            AppVisualStyle.transcriptBackground
        ],
        startPoint: .top,
        endPoint: .bottom
    )
    .ignoresSafeArea()
}
