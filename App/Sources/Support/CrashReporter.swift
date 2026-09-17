import Foundation
import MetricKit
import os

private let crashLog = Logger(subsystem: "local.ankivoice", category: "crash-reporter")

/// Collects MetricKit crash/hang diagnostics so a TestFlight crash can be
/// read back from Settings → Diagnostics without waiting on App Store Connect
/// symbolication. Payloads are written as JSON under Application Support and
/// the most recent handful are kept.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, Sendable {

    static let shared = CrashReporter()

    private static let keepCount = 5

    private override init() {
        super.init()
    }

    /// Call once at launch. MetricKit delivers diagnostics from previous runs
    /// shortly after subscription.
    func start() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !payload.crashDiagnostics.isNilOrEmpty
            || !payload.hangDiagnostics.isNilOrEmpty {
            Self.store(payload)
        }
        Self.prune()
    }

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics are not persisted; crashes and hangs are what
        // we need for triage.
    }

    // MARK: - Storage

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    private static func store(_ payload: MXDiagnosticPayload) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: payload.timeStampEnd)
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appendingPathComponent("crash-\(stamp).json")
            try payload.jsonRepresentation().write(to: url, options: .atomic)
            crashLog.error("[CRASH] stored diagnostic payload at \(url.lastPathComponent, privacy: .public)")
        } catch {
            crashLog.error("[CRASH] failed to store diagnostic: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func prune() {
        let files = storedReports()
        for url in files.dropFirst(keepCount) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stored reports, newest first.
    static func storedReports() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    /// Human-readable summary of stored reports for the diagnostics screen.
    static func summary() -> String {
        let reports = storedReports()
        guard !reports.isEmpty else {
            return "No crash or hang reports recorded on this device."
        }
        var out = "\(reports.count) diagnostic report(s), newest first:\n"
        for url in reports {
            out += "\n— \(url.lastPathComponent)\n"
            out += Self.describe(url)
        }
        return out
    }

    private static func describe(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "  (unreadable)\n"
        }
        var out = ""
        for crash in root["crashDiagnostics"] as? [[String: Any]] ?? [] {
            let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
            out += "  crash: \(meta["exceptionType"] ?? "?") / \(meta["signal"] ?? "?")"
            if let reason = meta["exceptionReason"] as? [String: Any] {
                out += " — \(reason["composedMessage"] ?? reason["exceptionName"] ?? "")"
            } else if let code = meta["terminationReason"] {
                out += " — \(code)"
            }
            out += "\n"
            out += "  app \(meta["appVersion"] ?? "?") (\(meta["appBuildVersion"] ?? "?")) on \(meta["osVersion"] ?? "?")\n"
            out += frames(from: crash["callStackTree"])
        }
        for hang in root["hangDiagnostics"] as? [[String: Any]] ?? [] {
            let meta = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
            out += "  hang: \(hang["hangDuration"] ?? "?") on \(meta["osVersion"] ?? "?")\n"
            out += frames(from: hang["callStackTree"])
        }
        return out.isEmpty ? "  (no crash or hang entries)\n" : out
    }

    /// The first thread's frames, unsymbolicated: binary name + offset is
    /// enough to symbolicate against the archived dSYM.
    private static func frames(from tree: Any?) -> String {
        guard let tree = tree as? [String: Any],
              let stacks = tree["callStacks"] as? [[String: Any]] else { return "" }
        var lines: [String] = []
        for stack in stacks {
            let attributed = stack["threadAttributed"] as? Bool ?? false
            guard attributed || stacks.count == 1 else { continue }
            var pending = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            var depth = 0
            while let frame = pending.first, depth < 24 {
                pending = frame["subFrames"] as? [[String: Any]] ?? []
                let binary = frame["binaryName"] as? String ?? "?"
                let offset = frame["offsetIntoBinaryTextSegment"] ?? 0
                lines.append("    \(depth). \(binary) +\(offset)")
                depth += 1
            }
            break
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
