import Foundation

public enum AppVersion {
    // Compared numerically per component, so 0.10.0 beats 0.9.0. Missing
    // components count as 0, and a leading "v" from a git tag is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate), rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    public static func components(_ version: String) -> [Int] {
        let trimmed = version.hasPrefix("v") ? version.dropFirst() : Substring(version)
        return trimmed.split(separator: ".").map { Int($0) ?? 0 }
    }
}
