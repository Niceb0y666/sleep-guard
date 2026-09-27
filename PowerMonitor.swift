import Foundation
import Darwin

/// The system-wide SleepDisabled setting. An unreadable setting is never
/// represented as `.allowed`.
enum SleepMode: Equatable {
    case allowed
    case disabled
    case unknown(String)
}

struct SleepCheckResult {
    let mode: SleepMode
    /// Time the check completed, including failed and timed-out checks.
    let checkedAt: Date
}

/// Read-only, asynchronous inspection of `/usr/bin/pmset -g`.
///
/// `check` may be called from any thread. Requests made during an existing
/// check share that check; every completion is delivered on the main queue.
final class PowerMonitor {
    private struct Query {
        let id: UUID
        let process: Process
        let timeout: DispatchWorkItem
        var completions: [(SleepCheckResult) -> Void]
    }

    private let queue = DispatchQueue(label: "SleepGuard.PowerMonitor", qos: .utility)
    private var query: Query?
    private let timeoutInterval: TimeInterval = 3

    func check(completion: @escaping (SleepCheckResult) -> Void) {
        queue.async {
            if self.query != nil {
                self.query?.completions.append(completion)
                return
            }
            self.start(completion: completion)
        }
    }

    private func start(completion: @escaping (SleepCheckResult) -> Void) {
        let id = UUID()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        // Use one stream so stderr cannot fill a separate unread pipe.
        process.standardError = pipe
        process.environment = ["LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let timeout = DispatchWorkItem { [weak self, weak process] in
            guard let self = self, self.query?.id == id else { return }
            if let process = process, process.isRunning {
                // pmset is a short-lived read-only subprocess. Kill it at the
                // deadline so a stuck query cannot accumulate child processes.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            self.finish(id: id, mode: .unknown("读取电源设置超时（3 秒）"))
        }
        query = Query(id: id, process: process, timeout: timeout, completions: [completion])
        queue.asyncAfter(deadline: .now() + timeoutInterval, execute: timeout)

        // Launching and all potentially blocking pipe/process operations stay
        // off both the main queue and the queue that enforces the deadline.
        DispatchQueue.global(qos: .utility).async {
            do {
                try process.run()
            } catch {
                self.queue.async {
                    self.finish(id: id, mode: .unknown("无法运行 pmset：\(error.localizedDescription)"))
                }
                return
            }
            self.queue.async {
                // A launch that returns after the deadline must also be
                // cleaned up; the already delivered timeout stays unchanged.
                if self.query?.id != id, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let mode: SleepMode
            if process.terminationReason != .exit || process.terminationStatus != 0 {
                mode = .unknown("pmset 执行失败（状态 \(process.terminationStatus)）")
            } else if let output = String(data: data, encoding: .utf8) {
                mode = Self.parse(output)
            } else {
                mode = .unknown("pmset 输出无法解码")
            }
            self.queue.async {
                self.finish(id: id, mode: mode)
            }
        }
    }

    private func finish(id: UUID, mode: SleepMode) {
        guard let current = query, current.id == id else { return }
        current.timeout.cancel()
        query = nil
        let result = SleepCheckResult(mode: mode, checkedAt: Date())
        DispatchQueue.main.async {
            for completion in current.completions {
                completion(result)
            }
        }
    }

    /// Accept only explicit 0/1/false/true values for the exact SleepDisabled
    /// field. Missing, malformed, or conflicting fields produce `.unknown`.
    static func parse(_ output: String) -> SleepMode {
        let field = "SleepDisabled"
        var parsed: SleepMode?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(field) else { continue }
            let suffix = String(line.dropFirst(field.count))
            // Avoid treating a similarly named setting as the requested field.
            guard suffix.isEmpty || suffix.first?.isWhitespace == true || suffix.first == "=" || suffix.first == ":" else { continue }
            var token = suffix.trimmingCharacters(in: .whitespaces)
            if token.first == "=" || token.first == ":" {
                token.removeFirst()
                token = token.trimmingCharacters(in: .whitespaces)
            }
            let mode: SleepMode
            switch token.lowercased() {
            case "0", "false": mode = .allowed
            case "1", "true": mode = .disabled
            default: return .unknown("SleepDisabled 的值无法识别")
            }
            if let previous = parsed, previous != mode {
                return .unknown("pmset 返回了冲突的 SleepDisabled 值")
            }
            parsed = mode
        }
        return parsed ?? .unknown("pmset 未返回 SleepDisabled 设置")
    }
}
