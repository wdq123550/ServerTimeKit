//
//  ServerTimeSyncer.swift
//
//  独立的服务器时间同步模块，可直接用于 SPM 包。
//  基于 mach_continuous_time 实现高精度时间锚定，不受用户修改系统时间、设备休眠影响。
//
//  ═══════════════════════════════════════════════════════
//  使用方式
//  ═══════════════════════════════════════════════════════
//
//  1. 在 App 启动时（如 AppDelegate / @main App.init）配置并启动：
//     (此操作不需要网络)
//     ServerTimeSyncer.shared.setup(
//         url: "https://advtimedown.cpcphone.com/adv_time/time/getCurrentTime",
//         cid: "5306",
//         aid: { YourUUIDProvider.getUUID() }
//     )
//     (此操作需要网络)
//     ServerTimeSyncer.shared.start()
//
//  2. 在任意位置获取服务器时间：
//
//     if let serverTime = ServerTimeSyncer.shared.now() {
//         print("服务器时间: \(serverTime)")
//     }
//
//  3. 判断是否已完成同步：
//
//     if ServerTimeSyncer.shared.hasSynced {
//         // 时间已就绪，可以安全使用
//     }
//
//  4. 调试模式（跳过网络请求，直接使用本地时间）：
//
//     ServerTimeSyncer.shared.useLocalTime = true
//
//  5. 监听基于服务器时间的跨天通知（默认开启，订阅即可）：
//
//     NotificationCenter.default.addObserver(
//         self,
//         selector: #selector(handleDayChanged),
//         name: ServerTimeSyncer.dayDidChangeNotification,
//         object: nil
//     )
//
//  ═══════════════════════════════════════════════════════
//  注意事项
//  ═══════════════════════════════════════════════════════
//
//  - 必须先调用 setup() 再调用 start()，否则会触发 assertionFailure。
//  - App 每次回到前台会自动重新同步一次，无需手动处理。
//  - now() 在尚未同步成功时返回 nil，请做好判空处理。
//  - 线程安全：可在任意线程调用 now()。
//  - 跨天检测基于服务器时间，不受用户手动修改系统时间影响。
//

import Foundation
import Observation
import UIKit

// MARK: - ServerTimeSyncer

/// 服务器时间同步器（单例）
///
/// 通过向服务器请求当前时间，结合 `mach_continuous_time` 本地锚点，
/// 提供不受用户修改系统时间、设备休眠影响的高精度服务器时间。
@Observable
public final class ServerTimeSyncer {

    public static let shared = ServerTimeSyncer()

    /// 基于服务器时间的跨天通知，跨天确认后通过 NotificationCenter 发出
    public static let dayDidChangeNotification = Notification.Name("ServerTimeSyncer.dayDidChange")

    /// 是否已成功同步过服务器时间
    public private(set) var hasSynced: Bool = false

    /// 设为 true 时跳过网络请求，直接使用本地时间（用于调试）
    public var useLocalTime: Bool = false

    private var url: String?
    private var cid: String?
    private var aid: (() -> String)?
    private var retryLimit: Int = 3

    private var timeBase: TimeInterval = 0
    private var localBase: TimeInterval = 0
    private var isFetching = false
    private let lock = NSLock()

    // 跨天刷新相关
    private var dailyCheckTimer: Timer?
    private let lastSyncTimestampKey = "ServerTimeSyncer.lastSyncTimestamp"

    private init() {}
}

// MARK: - Public

public extension ServerTimeSyncer {

    /// 初始化必要参数，在 `start()` 之前调用
    /// - Parameters:
    ///   - url: 完整请求地址，例如 `"https://advtimedown.cpcphone.com/adv_time/time/getCurrentTime"`
    ///   - cid: 项目渠道 ID
    ///   - aid: 用户唯一标识（每次请求动态获取）
    ///   - retryLimit: 请求失败重试次数，默认 3
    func setup(
        url: String,
        cid: String,
        aid: @escaping () -> String,
        retryLimit: Int = 3
    ) {
        self.url = url
        self.cid = cid
        self.aid = aid
        self.retryLimit = retryLimit

        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// 开始同步服务器时间
    func start() {
        sync(retryCount: retryLimit)
    }

    /// 获取当前服务器时间，未同步时返回 nil
    func now() -> Date? {
        if useLocalTime { return Date() }

        lock.lock()
        let tb = timeBase
        let lb = localBase
        lock.unlock()

        guard tb != 0 else { return nil }

        let elapsed = continuousTime() - lb
        return Date(timeIntervalSince1970: tb + elapsed)
    }
}

// MARK: - Private

private extension ServerTimeSyncer {

    /// 向服务器发起时间同步请求，成功后锚定 timeBase 和 localBase
    func sync(retryCount: Int) {
        if useLocalTime {
            lock.lock()
            timeBase = Date().timeIntervalSince1970
            localBase = continuousTime()
            hasSynced = true
            lock.unlock()
            return
        }

        guard let url, let cid, let aid else {
            assertionFailure("ServerTimeSyncer: 请先调用 setup() 配置必要参数")
            return
        }

        lock.lock()
        if isFetching { lock.unlock(); return }
        isFetching = true
        lock.unlock()

        let requestStartTime = continuousTime()

        var components = URLComponents(string: url)
        components?.queryItems = [
            URLQueryItem(name: "cid", value: cid),
            URLQueryItem(name: "aid", value: aid()),
            URLQueryItem(name: "country", value: Self.countryCode()),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier)
        ]

        guard let requestURL = components?.url else {
            lock.lock(); isFetching = false; lock.unlock()
            retry(count: retryCount)
            return
        }

        let task = URLSession.shared.dataTask(with: requestURL) { [weak self] data, _, error in
            guard let self else { return }

            self.lock.lock()
            self.isFetching = false
            self.lock.unlock()

            guard error == nil, let data else {
                self.retry(count: retryCount)
                return
            }

            let requestEndTime = self.continuousTime()
            let rtt = requestEndTime - requestStartTime

            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let success = json["success"] as? Int, success == 1,
                let currentTimeMillis = json["currentTime"] as? Int
            else {
                self.retry(count: retryCount)
                return
            }

            let serverTime = TimeInterval(currentTimeMillis) / 1000.0

            self.lock.lock()
            self.timeBase = serverTime + (rtt / 2.0)
            self.localBase = requestEndTime
            self.hasSynced = true
            self.lock.unlock()

            DispatchQueue.main.async {
                self.verifyDayChange()
                self.resetDailyTimer()
            }
        }
        task.resume()
    }

    /// 请求失败后延迟 1 秒重试，直到重试次数耗尽
    func retry(count: Int) {
        guard count > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.sync(retryCount: count - 1)
        }
    }

    /// 获取设备当前国家码，取自 Locale，兜底 "us"
    static func countryCode() -> String {
        Locale.current.region?.identifier.lowercased() ?? "us"
    }

    /// 系统 continuous time（秒），包含设备休眠时间
    func continuousTime() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        let nanos = Double(ticks) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000.0
    }

    /// App 回到前台时触发：重新同步时间 + 检查跨天
    @objc func appDidBecomeActive() {
        sync(retryCount: 1)
        verifyDayChange()
        resetDailyTimer()
    }

    // MARK: 跨天检测

    /// 对比服务器时间与上次记录的日期，若不在同一天则发送跨天通知
    func verifyDayChange() {
        let now = self.now() ?? Date()
        var lastTimestamp = UserDefaults.standard.double(forKey: lastSyncTimestampKey)

        if lastTimestamp == 0 {
            lastTimestamp = now.timeIntervalSince1970
            UserDefaults.standard.set(lastTimestamp, forKey: lastSyncTimestampKey)
        }

        let lastDate = Date(timeIntervalSince1970: lastTimestamp)

        if !Calendar.current.isDate(now, inSameDayAs: lastDate) {
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastSyncTimestampKey)
            NotificationCenter.default.post(name: Self.dayDidChangeNotification, object: nil)
            resetDailyTimer()
        }
    }

    /// 重置跨天 Timer，计算距离服务器时间次日 0 点的间隔并设定定时器
    func resetDailyTimer() {
        dailyCheckTimer?.invalidate()
        dailyCheckTimer = nil

        let now = self.now() ?? Date()
        let todayStart = Calendar.current.startOfDay(for: now)
        guard let nextMidnight = Calendar.current.date(byAdding: .day, value: 1, to: todayStart) else { return }

        let interval = nextMidnight.timeIntervalSince(now)
        guard interval > 0 else {
            verifyDayChange()
            return
        }

        dailyCheckTimer = Timer.scheduledTimer(
            timeInterval: interval,
            target: self,
            selector: #selector(dailyTimerFired),
            userInfo: nil,
            repeats: false
        )
    }

    /// 跨天 Timer 触发时的回调，验证跨天并重置下一轮 Timer
    @objc func dailyTimerFired() {
        verifyDayChange()
        resetDailyTimer()
    }
}

