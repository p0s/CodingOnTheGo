import SwiftUI

struct ProductSupportButtonRow: View {
    let privacyAccessibilityIdentifier: String
    let supportAccessibilityIdentifier: String

    var body: some View {
        HStack(spacing: 12) {
            Link(destination: ProductSupportLinks.privacyPolicyURL) {
                Label("Privacy Policy", systemImage: "lock.doc")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(privacyAccessibilityIdentifier)

            Link(destination: ProductSupportLinks.supportURL) {
                Label("Support", systemImage: "questionmark.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(supportAccessibilityIdentifier)
        }
    }
}
