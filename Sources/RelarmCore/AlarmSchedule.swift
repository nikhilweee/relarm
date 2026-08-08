import Foundation

public struct AlarmConfiguration: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var soundName: String
    public var secondsSinceMidnight: Int
    public var interval: Int
    public var nextFireDate: Date

    public init(id: UUID = UUID(), name: String, isEnabled: Bool = true, soundName: String = "Glass",
                secondsSinceMidnight: Int, interval: Int, nextFireDate: Date) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.soundName = soundName
        self.secondsSinceMidnight = secondsSinceMidnight
        self.interval = interval
        self.nextFireDate = nextFireDate
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, soundName, secondsSinceMidnight, interval, nextFireDate
    }

    // Relarm 0.1 stored a single unnamed alarm. Decode it as a useful default
    // so existing users keep their schedule when upgrading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Alarm"
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        soundName = try container.decodeIfPresent(String.self, forKey: .soundName) ?? "Glass"
        secondsSinceMidnight = try container.decode(Int.self, forKey: .secondsSinceMidnight)
        interval = try container.decode(Int.self, forKey: .interval)
        nextFireDate = try container.decode(Date.self, forKey: .nextFireDate)
    }
}

public enum AlarmSchedule {
    /// The selected wall-clock time today, unless it has passed; then tomorrow.
    public static func initialFireDate(secondsSinceMidnight: Int, now: Date = Date(),
                                       calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        let candidate = calendar.date(byAdding: .second, value: secondsSinceMidnight,
                                      to: startOfToday)!
        return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)!
    }

    /// Keeps the cadence anchored to the original schedule and skips missed alerts.
    public static func nextFutureDate(after date: Date, interval: Int, now: Date = Date()) -> Date {
        precondition(interval > 0)
        guard date <= now else { return date }
        let elapsed = now.timeIntervalSince(date)
        let intervalsToSkip = Int(floor(elapsed / Double(interval))) + 1
        return date.addingTimeInterval(Double(intervalsToSkip * interval))
    }
}

public func parseDuration(_ input: String) -> Int? {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty else { return nil }
    if text.contains(":") {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let values = parts.compactMap { Int($0) }
        guard values.count == parts.count else { return nil }
        switch values.count {
        case 2:
            let total = values[0] * 60 + values[1]
            return total > 0 ? total : nil
        case 3:
            let total = values[0] * 3600 + values[1] * 60 + values[2]
            return total > 0 ? total : nil
        default: return nil
        }
    }
    if let minutes = Int(text) { return minutes > 0 ? minutes * 60 : nil }

    let regex = try! NSRegularExpression(pattern: #"(\d+)\s*(h(?:ours?|rs?)?|m(?:ins?|inutes?)?|s(?:ecs?|econds?)?)"#)
    let range = NSRange(text.startIndex..., in: text)
    var total = 0
    for match in regex.matches(in: text, range: range) {
        let value = Int((text as NSString).substring(with: match.range(at: 1)))!
        switch (text as NSString).substring(with: match.range(at: 2)).prefix(1) {
        case "h": total += value * 3600
        case "m": total += value * 60
        default: total += value
        }
    }
    let leftover = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        .replacingOccurrences(of: ",", with: "")
        .trimmingCharacters(in: .whitespaces)
    return total > 0 && leftover.isEmpty ? total : nil
}

public func durationLabel(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    var parts: [String] = []
    if hours > 0 { parts.append("\(hours) hr") }
    if minutes > 0 { parts.append("\(minutes) min") }
    if remainder > 0 { parts.append("\(remainder) sec") }
    return parts.joined(separator: " ")
}
