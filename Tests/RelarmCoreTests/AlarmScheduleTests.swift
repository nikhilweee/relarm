import XCTest
@testable import RelarmCore

final class AlarmScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func testFirstOccurrenceUsesTodayWhenTimeIsAhead() {
        let now = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01 12:00 UTC
        let date = AlarmSchedule.initialFireDate(secondsSinceMidnight: 13 * 3600, now: now, calendar: calendar)
        XCTAssertEqual(date.timeIntervalSince(now), 3600, accuracy: 0.1)
    }

    func testFirstOccurrenceUsesTomorrowWhenTimeHasPassed() {
        let now = Date(timeIntervalSince1970: 1_704_110_400) // 2024-01-01 12:00 UTC
        let date = AlarmSchedule.initialFireDate(secondsSinceMidnight: 11 * 3600, now: now, calendar: calendar)
        XCTAssertEqual(date.timeIntervalSince(now), 23 * 3600, accuracy: 0.1)
    }

    func testMissedOccurrencesAdvanceOnOriginalCadence() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(AlarmSchedule.nextFutureDate(after: Date(timeIntervalSince1970: 9_000), interval: 300, now: now),
                       Date(timeIntervalSince1970: 10_200))
    }

    func testDurationParser() {
        XCTAssertEqual(parseDuration("1h 30m"), 5400)
        XCTAssertEqual(parseDuration("1:30"), 90)
        XCTAssertEqual(parseDuration("25"), 1500)
        XCTAssertNil(parseDuration("nope"))
    }

    func testCountdownLabel() {
        XCTAssertEqual(countdownLabel(0), "1 sec")
        XCTAssertEqual(countdownLabel(45), "45 sec")
        XCTAssertEqual(countdownLabel(60), "1 min")
        XCTAssertEqual(countdownLabel(61), "2 min")
        XCTAssertEqual(countdownLabel(5400), "1 hr 30 min")
    }

    func testLegacyAlarmDecodesWithUsefulDefaults() throws {
        let data = #"{"secondsSinceMidnight":3600,"interval":300,"nextFireDate":0}"#.data(using: .utf8)!
        let alarm = try JSONDecoder().decode(AlarmConfiguration.self, from: data)
        XCTAssertEqual(alarm.name, "Alarm")
        XCTAssertTrue(alarm.isEnabled)
        XCTAssertEqual(alarm.soundName, "Glass")
        XCTAssertEqual(alarm.ringDuration, AlarmConfiguration.defaultRingDuration)
    }

    func testRingDurationRoundTrips() throws {
        let alarm = AlarmConfiguration(name: "Stretch", secondsSinceMidnight: 0, interval: 60,
                                       nextFireDate: Date(timeIntervalSince1970: 0), ringDuration: 0)
        let decoded = try JSONDecoder().decode(AlarmConfiguration.self, from: JSONEncoder().encode(alarm))
        XCTAssertEqual(decoded, alarm)
    }
}
