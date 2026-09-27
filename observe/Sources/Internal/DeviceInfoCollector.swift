import Foundation
import LocalAuthentication
import UIKit

/// Native device info collection. Uses system frameworks only, and only APIs that are cheap,
/// non-blocking, non-throwing and permission-free, so no probe threads or timeouts are needed.
/// Bluetooth is deliberately never probed: instantiating `CBCentralManager` triggers the
/// Bluetooth permission dialog, and every iPhone has Bluetooth anyway. The wire field stays
/// absent.
///
/// Runs on the main actor (UIKit reads); the result is handed back to the SDK actor.
enum DeviceInfoCollector {
    @MainActor
    static func collect() -> WireDeviceInfoDataApp {
        WireDeviceInfoDataApp(
            osName: "iOS",
            osVersion: UIDevice.current.systemVersion,
            model: machineIdentifier(),
            brand: "Apple",
            appName: appName(),
            appVersion: appVersion(),
            deviceOwnerAuth: deviceOwnerAuth(),
            locale: localeTag(),
            screen: screen()
        )
    }

    /// Machine identifier, e.g. "iPhone15,3": the model granularity the analysis needs
    /// (`UIDevice.model` is just "iPhone").
    private static func machineIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8)
        }
    }

    private static func appName() -> String? {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleDisplayName"] as? String ?? info?["CFBundleName"] as? String
    }

    private static func appVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// True BCP-47 tag ("de-DE"). `Locale.identifier` would leak ICU keyword extensions
    /// (`de_DE@calendar=buddhist`) into cross-platform grouping.
    private static func localeTag() -> String? {
        if #available(iOS 16.0, *) {
            return Locale.current.identifier(.bcp47)
        }
        let locale = Locale.current
        var parts: [String] = []
        if let language = locale.languageCode { parts.append(language) }
        if let script = locale.scriptCode { parts.append(script) }
        if let region = locale.regionCode { parts.append(region) }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    /// Device-owner authentication capability as none | code | bio-face | bio-touch | bio.
    /// `canEvaluatePolicy` is a capability check; it never prompts.
    private static func deviceOwnerAuth() -> String {
        let context = LAContext()
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            switch context.biometryType {
            case .faceID: return "bio-face"
            case .touchID: return "bio-touch"
            default: return "bio"
            }
        }
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            return "code"
        }
        return "none"
    }

    /// Screen size in points plus the scale factor, the same decomposition as the wire schema
    /// (`widthPoints`/`heightPoints`/`scale`).
    @MainActor
    private static func screen() -> WireAppScreen? {
        let bounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        guard scale > 0 else { return nil }
        return WireAppScreen(
            widthPoints: Float(bounds.width),
            heightPoints: Float(bounds.height),
            scale: Float(scale)
        )
    }
}
