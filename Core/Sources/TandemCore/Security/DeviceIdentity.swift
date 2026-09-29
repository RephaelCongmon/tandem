import Foundation
import IOKit.ps

/// How this Mac presents itself to peers. `id` is a random UUID created once per
/// install (per profile) and never derived from hardware identifiers.
public struct DeviceIdentity: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Hardware model identifier such as "MacBookPro18,1" or "Mac15,3".
    public var model: String

    public init(id: String, name: String, model: String) {
        self.id = id
        self.name = name
        self.model = model
    }

    /// Loads the persisted identity or creates one. The display name follows the
    /// Mac's name unless the user set a custom one.
    public static func loadOrCreate(defaults: UserDefaults, customName: String? = nil) -> DeviceIdentity {
        let key = "tandem.deviceID"
        let id: String
        if let existing = defaults.string(forKey: key), UUID(uuidString: existing) != nil {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: key)
        }
        let trimmed = customName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DeviceIdentity(id: id, name: trimmed.isEmpty ? systemName : trimmed, model: localModelDescriptor)
    }

    public static var systemName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// `hw.model`, suffixed with ";laptop" when this Mac has an internal battery so
    /// peers can pick the right icon (Apple silicon ids like "Mac14,2" don't say).
    public static var localModelDescriptor: String {
        hasInternalBattery ? "\(hardwareModel);laptop" : hardwareModel
    }

    public static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static var hasInternalBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType { return true }
        }
        return false
    }
}

public extension DeviceIdentity {
    /// SF Symbol that best matches the peer's hardware.
    var systemImage: String { Self.systemImage(forModel: model) }

    var isLaptop: Bool {
        let lower = model.lowercased()
        return lower.hasSuffix(";laptop") || lower.hasPrefix("macbook")
    }

    static func systemImage(forModel model: String) -> String {
        let lower = model.lowercased()
        if lower.hasSuffix(";laptop") || lower.hasPrefix("macbook") { return "laptopcomputer" }
        if lower.hasPrefix("imac") { return "desktopcomputer" }
        if lower.hasPrefix("macmini") { return "macmini" }
        if lower.hasPrefix("macpro") { return "macpro.gen3" }
        return "desktopcomputer"
    }
}
