# SwiftUI References

Use these references when building the client and companion UI.

## Apple references
- SwiftUI overview: https://developer.apple.com/xcode/swiftui/
- SwiftUI documentation: https://developer.apple.com/documentation/swiftui/
- NavigationSplitView: https://developer.apple.com/documentation/swiftui/navigationsplitview
- NavigationStack: https://developer.apple.com/documentation/swiftui/navigationstack
- Scene and app life cycle: https://developer.apple.com/documentation/swiftui/scene
- Accessibility in SwiftUI: https://developer.apple.com/documentation/accessibility/enhancing-the-accessibility-of-your-swiftui-app
- State and data flow: https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app

## Focus areas
- App / Scene structure
- NavigationSplitView and NavigationStack
- Multiwindow scene support on iPad
- Observable state flow and task cancellation
- Accessibility and dynamic type behavior
- Keyboard support on iPad and macOS

## Project interpretation
- iPhone should optimize for quick reconnect and single-session focus
- iPad should support:
  - persistent machine sidebar
  - route inspector
  - two host sessions side by side when feasible
  - keyboard-first conversation controls
- macOS companion UI should optimize for diagnostics, presence, and host controls rather than full mobile-thread editing
