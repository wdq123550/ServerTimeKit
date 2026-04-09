import Foundation
import Testing
@testable import ServerTimeKit

@Suite(.serialized)
struct ServerTimeSyncerTests {

    let syncer = ServerTimeSyncer.shared

    // MARK: - 基本属性

    @Test func notificationName() {
        #expect(
            ServerTimeSyncer.dayDidChangeNotification.rawValue
            == "ServerTimeSyncer.dayDidChange"
        )
    }

    @Test func singletonIdentity() {
        #expect(ServerTimeSyncer.shared === ServerTimeSyncer.shared)
    }

    // MARK: - useLocalTime 模式

    @Test func localModeNowReturnsDate() {
        syncer.useLocalTime = true
        defer { syncer.useLocalTime = false }

        let date = syncer.now()
        #expect(date != nil)
    }

    @Test func localModeNowIsCloseToSystemTime() {
        syncer.useLocalTime = true
        defer { syncer.useLocalTime = false }

        let before = Date()
        let serverDate = syncer.now()
        let after = Date()

        #expect(serverDate != nil)
        if let serverDate {
            #expect(serverDate.timeIntervalSince(before) >= 0)
            #expect(after.timeIntervalSince(serverDate) >= 0)
        }
    }

    @Test func localModeSyncSetsHasSynced() {
        syncer.useLocalTime = true
        defer { syncer.useLocalTime = false }

        syncer.start()
        #expect(syncer.hasSynced == true)
    }

    // MARK: - setup

    @Test func setupAcceptsParameters() {
        syncer.setup(
            url: "https://example.com/time",
            cid: "test_cid",
            aid: { "test-uuid" },
            retryLimit: 5
        )
    }

    @Test func setupAcceptsDefaultRetryLimit() {
        syncer.setup(
            url: "https://example.com/time",
            cid: "test_cid",
            aid: { "test-uuid" }
        )
    }

    // MARK: - 多次调用 now() 的单调性

    @Test func localModeNowIsMonotonic() {
        syncer.useLocalTime = true
        defer { syncer.useLocalTime = false }

        let first = syncer.now()
        let second = syncer.now()

        #expect(first != nil)
        #expect(second != nil)
        if let first, let second {
            #expect(second >= first)
        }
    }
}
