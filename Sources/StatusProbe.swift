import CoreLocation
import CoreTelephony
import Foundation
import Network
import UIKit
import os

/// Cached device/network state behind `GET /_status`. Values are refreshed by path-monitor callbacks
/// and notifications; a request only reads the cache, so it never touches the main thread.
final class StatusProbe {
    static let shared = StatusProbe()

    private struct Cache {
        var cellular: Bool?
        var wifi: Bool?
        var expensive: Bool?
        var constrained: Bool?
        var radio: String?
        var appState: String?
        var battery: Double?
        var batteryState: String?
        var audioPlaying: Bool?
        var location: String?
        var startedAt: Date?
    }

    private let cache = OSAllocatedUnfairLock(initialState: Cache())
    private let monitorQueue = DispatchQueue(label: "status.monitor", qos: .utility)
    private let cellMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let telephony = CTTelephonyNetworkInfo()
    private var begun = false

    /// Call once from the main thread.
    @MainActor func begin() {
        guard !begun else { return }
        begun = true

        cellMonitor.pathUpdateHandler = { [weak self] p in
            self?.cache.withLock {
                $0.cellular = p.status == .satisfied
                $0.expensive = p.isExpensive
                $0.constrained = p.isConstrained
            }
        }
        wifiMonitor.pathUpdateHandler = { [weak self] p in self?.cache.withLock { $0.wifi = p.status == .satisfied } }
        cellMonitor.start(queue: monitorQueue)
        wifiMonitor.start(queue: monitorQueue)

        refreshRadio()
        NotificationCenter.default.addObserver(forName: .CTServiceRadioAccessTechnologyDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.refreshRadio()
        }

        let dev = UIDevice.current
        dev.isBatteryMonitoringEnabled = true
        refreshBattery()
        let nc = NotificationCenter.default
        for n in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshBattery() }
        }
        refreshAppState()
        for n in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
                  UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.refreshAppState() }
        }
    }

    // MARK: writers (called from main)
    func serverStarted() { cache.withLock { $0.startedAt = Date() } }
    func serverStopped() { cache.withLock { $0.startedAt = nil } }
    func setAudioPlaying(_ v: Bool) { cache.withLock { $0.audioPlaying = v } }
    func setLocation(_ s: CLAuthorizationStatus) {
        let v: String
        switch s {
        case .authorizedAlways: v = "always"
        case .authorizedWhenInUse: v = "whenInUse"
        case .denied: v = "denied"
        case .restricted: v = "restricted"
        default: v = "notDetermined"
        }
        cache.withLock { $0.location = v }
    }

    @MainActor private func refreshAppState() {
        let v: String
        switch UIApplication.shared.applicationState {
        case .active: v = "foreground"
        case .inactive: v = "inactive"
        default: v = "background"
        }
        cache.withLock { $0.appState = v }
    }

    @MainActor private func refreshBattery() {
        let d = UIDevice.current
        let level: Double? = d.batteryLevel < 0 ? nil : Double(d.batteryLevel)
        let st: String
        switch d.batteryState {
        case .charging: st = "charging"
        case .full: st = "full"
        case .unplugged: st = "unplugged"
        default: st = "unknown"
        }
        cache.withLock { $0.battery = level; $0.batteryState = st }
    }

    private func refreshRadio() {
        let raw = telephony.serviceCurrentRadioAccessTechnology?.sorted { $0.key < $1.key }.first?.value
        let v: String?
        switch raw {
        case nil: v = nil
        case CTRadioAccessTechnologyNR: v = "NR"
        case CTRadioAccessTechnologyNRNSA: v = "NRNSA"
        case CTRadioAccessTechnologyLTE: v = "LTE"
        case CTRadioAccessTechnologyWCDMA: v = "WCDMA"
        default: v = "other"
        }
        cache.withLock { $0.radio = v }
    }

    // MARK: response
    /// Full HTTP response. `proxy` carries the counters owned by ProxyServer.
    func httpResponse(live: Int, bytes: UInt64, sessions: UInt64, dialFail: UInt64) -> Data {
        let c = cache.withLock { $0 }
        let now = Date()
        let iso = ISO8601DateFormatter()
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let info = Bundle.main.infoDictionary
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        default: thermal = "critical"
        }
        let body: [String: Any] = [
            "v": 1,
            "at": iso.string(from: now),
            "app": [
                "version": opt(info?["CFBundleShortVersionString"]),
                "build": opt(info?["CFBundleVersion"]),
                "state": opt(c.appState),
                "uptimeSec": opt(c.startedAt.map { Int(now.timeIntervalSince($0)) }),
                "startedAt": opt(c.startedAt.map { iso.string(from: $0) }),
            ],
            "proxy": ["live": live, "bytesTotal": bytes, "sessionsTotal": sessions, "dialFailTotal": dialFail],
            "net": [
                "cellular": opt(c.cellular), "wifi": opt(c.wifi), "radio": opt(c.radio),
                "expensive": opt(c.expensive), "constrained": opt(c.constrained),
            ],
            "device": [
                "battery": opt(c.battery), "batteryState": opt(c.batteryState),
                "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled, "thermal": thermal,
            ],
            "keepalive": ["audioPlaying": opt(c.audioPlaying), "location": opt(c.location)],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + json
    }
}
