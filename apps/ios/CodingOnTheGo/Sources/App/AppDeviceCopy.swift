import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
enum AppDeviceCopy {
    static var deviceName: String {
#if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "iPad"
        case .phone:
            return "iPhone"
        default:
            return "device"
        }
#else
        return "device"
#endif
    }

    static var thisDevice: String {
        deviceName == "device" ? "this device" : "this \(deviceName)"
    }

    static var thisDeviceCapitalized: String {
        deviceName == "device" ? "This device" : "This \(deviceName)"
    }

    static var isPhone: Bool {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }
}
