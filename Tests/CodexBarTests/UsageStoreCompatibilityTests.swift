import Foundation
import XCTest
@testable import CodexBar

final class UsageStoreCompatibilityTests: XCTestCase {
    func testLoadsPreviouslySavedNonOptionalFiveHourCache() throws {
        try withStore { defaults, store in
            // 旧版 Codable 写出的真实结构；日期使用默认的参考日期秒数。
            let data = Data("""
            {"fiveHour":{"remainingPercent":80},"weekly":{"remainingPercent":75},"fetchedAt":123}
            """.utf8)
            defaults.set(data, forKey: "snapshot")

            let snapshot = try XCTUnwrap(store.load())
            XCTAssertEqual(snapshot.fiveHour?.remainingPercent, 80)
            XCTAssertEqual(snapshot.weekly.remainingPercent, 75)
            XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSinceReferenceDate: 123))
        }
    }

    func testRoundTripsWeeklyOnlyCache() throws {
        try withStore { _, store in
            let snapshot = UsageSnapshot(
                fiveHour: nil,
                weekly: .init(remainingPercent: 75, resetsAt: nil),
                fetchedAt: Date(timeIntervalSinceReferenceDate: 123)
            )

            store.save(snapshot)

            XCTAssertEqual(store.load(), snapshot)
            XCTAssertNil(store.load()?.fiveHour)
        }
    }

    func testRejectsCacheWithoutRequiredWeeklyWindow() throws {
        try withStore { defaults, store in
            defaults.set(Data("""
            {"fiveHour":{"remainingPercent":80},"fetchedAt":123}
            """.utf8), forKey: "snapshot")

            XCTAssertNil(store.load())
        }
    }

    private func withStore(_ body: (UserDefaults, UsageStore) throws -> Void) throws {
        let suite = "CodexBarTests.CacheCompatibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, UsageStore(defaults: defaults, key: "snapshot"))
    }
}
