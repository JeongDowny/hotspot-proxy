import Foundation
import os

/// Append-only diagnostics log in the App Group container, so it can be pulled from a Mac with
/// `xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier <group> --source diag.log`.
/// Used to learn *why* iOS stopped the proxy (interruption, suspension, termination, memory).
enum Diag {
    private static let q = DispatchQueue(label: "diag")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    static var url: URL? {
        // Under Library/ because devicectl refuses to copy files at the container root.
        guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStore.appGroup)?.appendingPathComponent("Library/Diag") else { return nil }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("diag.log")
    }
    static func log(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        os_log("%{public}@", log: OSLog(subsystem: "hotspotproxy", category: "diag"), msg)
        q.async {
            guard let u = url, let d = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(d); try? h.close() }
            else { try? d.write(to: u) }
            // keep the file small
            if let a = try? FileManager.default.attributesOfItem(atPath: u.path), (a[.size] as? Int ?? 0) > 512_000,
               let s = try? String(contentsOf: u, encoding: .utf8) {
                try? s.suffix(256_000).write(to: u, atomically: true, encoding: .utf8)
            }
        }
    }
}
