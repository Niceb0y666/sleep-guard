import Foundation
import Darwin

/// `.commandCompleted` means only that the authorized command exited normally.
/// Always obtain a fresh PowerMonitor reading before claiming sleep is enabled.
enum SleepRecoveryOutcome: Equatable {
    case commandCompleted
    case cancelled
    case timedOut
    case failed(String)
}

struct SleepRecoveryResult {
    let outcome: SleepRecoveryOutcome
    let completedAt: Date
}

struct SleepRecoveryExecution {
    let status: Int32
    let terminatedBySignal: Bool
    let output: String
}

/// The runner seam exists for tests; the production runner accepts no command,
/// password, user-supplied script, or privilege configuration.
protocol SleepRecoveryRunner: AnyObject {
    // These entry points must return promptly; the production implementation
    // runs its launch/pipe work in the background.
    func start(completion: @escaping (Result<SleepRecoveryExecution, Error>) -> Void)
    func cancel()
}

/// Restores only the global SleepDisabled switch, using the macOS administrator
/// authorization dialog. Concurrent restore requests share one operation and
/// all completions arrive on the main queue. No password or helper is retained.
final class SleepRecovery {
    static let authorizationScript = """
    try
        do shell script "/usr/bin/pmset -a disablesleep 0" with administrator privileges
        return "SLEEP_GUARD_COMMAND_COMPLETED"
    on error errorMessage number errorNumber
        if errorNumber is -128 then
            return "SLEEP_GUARD_AUTH_CANCELLED:-128"
        end if
        if (length of errorMessage) > 1000 then
            set errorMessage to text 1 thru 1000 of errorMessage
        end if
        return "SLEEP_GUARD_ERROR:" & (errorNumber as text) & ":" & errorMessage
    end try
    """

    private struct Operation {
        let id: UUID
        let runner: SleepRecoveryRunner
        let timeout: DispatchWorkItem
        var completions: [(SleepRecoveryResult) -> Void]
    }

    private let queue = DispatchQueue(label: "SleepGuard.SleepRecovery", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()
    private let timeoutInterval: TimeInterval
    private let runnerFactory: () -> SleepRecoveryRunner
    private var operation: Operation?

    init(timeoutInterval: TimeInterval = 120,
         runnerFactory: @escaping () -> SleepRecoveryRunner = { AdministratorSleepRecoveryRunner() }) {
        precondition(timeoutInterval.isFinite && timeoutInterval > 0)
        self.timeoutInterval = timeoutInterval
        self.runnerFactory = runnerFactory
        queue.setSpecific(key: queueKey, value: ())
    }

    func restore(completion: @escaping (SleepRecoveryResult) -> Void) {
        queue.async { [self] in
            if self.operation != nil {
                self.operation?.completions.append(completion)
                return
            }
            let id = UUID()
            let runner = self.runnerFactory()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self, let operation = self.operation, operation.id == id else { return }
                operation.runner.cancel()
                // Killing osascript cannot undo a privileged command that has
                // already started. Treat timeout as uncertain and recheck.
                self.finish(id: id, outcome: .timedOut)
            }
            self.operation = Operation(id: id, runner: runner, timeout: timeout, completions: [completion])
            self.queue.asyncAfter(deadline: .now() + self.timeoutInterval, execute: timeout)
            runner.start { execution in
                self.queue.async {
                    let outcome: SleepRecoveryOutcome
                    switch execution {
                    case .success(let result): outcome = Self.classify(result)
                    case .failure(let error): outcome = .failed("无法启动系统授权：\(error.localizedDescription)")
                    }
                    self.finish(id: id, outcome: outcome)
                }
            }
        }
    }

    /// Also usable during application termination. It synchronizes only brief
    /// state bookkeeping, requests immediate subprocess termination, and never
    /// waits for authorization or the subprocess to exit.
    func cancel() {
        let cancelCurrent = {
            guard let current = self.operation else { return }
            current.runner.cancel()
            self.finish(id: current.id, outcome: .cancelled)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil { cancelCurrent() }
        else { queue.sync(execute: cancelCurrent) }
    }

    private func finish(id: UUID, outcome: SleepRecoveryOutcome) {
        guard let current = operation, current.id == id else { return }
        current.timeout.cancel()
        operation = nil
        let result = SleepRecoveryResult(outcome: outcome, completedAt: Date())
        DispatchQueue.main.async {
            for completion in current.completions { completion(result) }
        }
    }

    static func classify(_ execution: SleepRecoveryExecution) -> SleepRecoveryOutcome {
        let output = execution.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !execution.terminatedBySignal else { return .failed("系统授权进程被中断，请重新检测休眠状态") }
        if execution.status == 0 {
            if output == "SLEEP_GUARD_COMMAND_COMPLETED" { return .commandCompleted }
            if output == "SLEEP_GUARD_AUTH_CANCELLED:-128" { return .cancelled }
            if output.hasPrefix("SLEEP_GUARD_ERROR:") {
                let parts = output.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count == 3, let errorNumber = Int(parts[1]) {
                    if errorNumber == -128 { return .cancelled }
                    let detail = String(parts[2].prefix(600))
                    return .failed("系统授权或恢复命令失败（\(errorNumber)）：\(detail)")
                }
            }
            return .failed("恢复命令没有返回明确的执行结果，请重新检测休眠状态")
        }
        // osascript itself can report an uncaught cancellation. Match the
        // numeric AppleScript error, not a localized 'cancel' word or a mere
        // occurrence of -128 in unrelated output.
        if output.range(of: #"\(-128\)\s*$"#, options: .regularExpression) != nil {
            return .cancelled
        }
        let detail = String(output.prefix(600))
        return .failed("系统授权或恢复命令失败（状态 \(execution.status)）" + (detail.isEmpty ? "" : "：\(detail)"))
    }
}

final class AdministratorSleepRecoveryRunner: SleepRecoveryRunner {
    private let queue = DispatchQueue(label: "SleepGuard.SleepRecoveryProcess", qos: .utility)
    private let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var launched = false

    func start(completion: @escaping (Result<SleepRecoveryExecution, Error>) -> Void) {
        queue.async {
            self.lock.lock()
            guard !self.started && !self.cancelled else { self.lock.unlock(); return }
            self.started = true
            self.lock.unlock()
            let pipe = Pipe()
            self.process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            self.process.arguments = ["-e", SleepRecovery.authorizationScript]
            self.process.standardInput = FileHandle.nullDevice
            self.process.standardOutput = pipe
            self.process.standardError = pipe
            self.process.environment = ["LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            do {
                try self.process.run()
            } catch {
                completion(.failure(error))
                return
            }
            self.lock.lock()
            self.launched = true
            // If cancellation happened during launch, terminate before reading
            // the pipe. This closes the launch-versus-timeout race.
            if self.cancelled && self.process.isRunning {
                _ = Darwin.kill(self.process.processIdentifier, SIGKILL)
            }
            self.lock.unlock()
            DispatchQueue.global(qos: .utility).async {
                // The fixed script emits one small result (its error message
                // is capped at 1000 characters), so it cannot fill this pipe.
                self.process.waitUntilExit()
                self.lock.lock()
                self.launched = false
                self.lock.unlock()
                let data: Data
                do {
                    // Never wait for EOF: an authorization service or child
                    // may still hold an inherited pipe descriptor after the
                    // launcher exits or is killed.
                    data = try Self.readAvailableOutput(from: pipe.fileHandleForReading)
                } catch {
                    completion(.failure(error))
                    return
                }
                guard let output = String(data: data, encoding: .utf8) else {
                    completion(.failure(NSError(domain: "SleepGuard.SleepRecovery", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "系统授权返回了无法解码的结果"])))
                    return
                }
                completion(.success(SleepRecoveryExecution(status: self.process.terminationStatus,
                    terminatedBySignal: self.process.terminationReason != .exit, output: output)))
            }
        }
    }

    func cancel() {
        // The lock is never held across launch, pipe reads or process waits.
        // Run the kill now so application exit does not leave it merely queued.
        lock.lock()
        cancelled = true
        if launched && process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        lock.unlock()
    }

    static func readAvailableOutput(from handle: FileHandle) throws -> Data {
        defer { try? handle.close() }
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "无法读取系统授权结果"])
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard data.count + count <= 16_384 else {
                    throw NSError(domain: "SleepGuard.SleepRecovery", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "系统授权返回的结果过长"])
                }
                data.append(contentsOf: bytes.prefix(count))
            } else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                return data
            } else if errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "无法读取系统授权结果"])
            }
        }
    }
}
