import Foundation

/// A dotted version such as "1.2.3", compared number by number ("1.10" is newer than "1.9").
/// A leading "v" (as in release tags) is ignored, and missing parts count as zero.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let number = Int(part), number >= 0 else { return nil }
            numbers.append(number)
        }
        components = numbers
    }

    /// The version of the running app (`CFBundleShortVersionString`).
    public static var current: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }

    private var significant: [Int] {
        var parts = components
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { lhs.significant == rhs.significant }

    public func hash(into hasher: inout Hasher) { hasher.combine(significant) }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}
