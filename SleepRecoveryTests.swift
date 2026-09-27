import Foundation

/// No test launches osascript, requests administrator access, or runs pmset.
private final class MockRecoveryRunner: SleepRecoveryRunner {
    private let lock = NSLock()
    private var completion: ((Result<SleepRecoveryExecution, Error>) -> Void)?
    private var starts = 0
    private var cancellations = 0
    var startCount: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations }

    func start(completion: @escaping (Result<SleepRecoveryExecution, Error>) -> Void) {
        lock.lock()
        starts += 1
        self.completion = completion
        lock.unlock()
    }

    func cancel() { lock.lock(); cancellations += 1; lock.unlock() }

    func resolve(_ result: Result<SleepRecoveryExecution, Error>) {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(result)
    }
}

@main
struct SleepRecoveryTests {
    static func main() {
        testFixedCommand()
        testClassification()
        testMergedRequests()
        testLaunchFailure()
        testTimeoutAndLateCompletion()
        testCancellation()
        testPresentationBoundaries()
        testNonblockingPipeRead()
        print("SleepRecovery: fixed command, 11 result cases, merging, main-thread delivery, launch failure, timeout, late completion, cancellation, 6 presentation cases, inherited pipe without EOF passed (no authorization requested)")
    }

    private static func execution(_ status: Int32, _ output: String, signalled: Bool = false) -> SleepRecoveryExecution {
        SleepRecoveryExecution(status: status, terminatedBySignal: signalled, output: output)
    }

    private static func testFixedCommand() {
        let script = SleepRecovery.authorizationScript
        precondition(script.components(separatedBy: "do shell script").count == 2)
        precondition(script.contains("do shell script \"/usr/bin/pmset -a disablesleep 0\" with administrator privileges"))
        precondition(!script.contains("password "))
        precondition(!script.contains("sudo"))
    }

    private static func testClassification() {
        precondition(SleepRecovery.classify(execution(0, "SLEEP_GUARD_COMMAND_COMPLETED\n")) == .commandCompleted)
        precondition(SleepRecovery.classify(execution(0, "SLEEP_GUARD_AUTH_CANCELLED:-128")) == .cancelled)
        precondition(SleepRecovery.classify(execution(0, "SLEEP_GUARD_ERROR:-128:用户取消。")) == .cancelled)
        precondition(SleepRecovery.classify(execution(1, "execution error: User canceled. (-128)\n")) == .cancelled)
        precondition(SleepRecovery.classify(execution(1, "执行错误：用户已取消。 (-128)")) == .cancelled)
        for result in [
            execution(0, ""),
            execution(0, "SLEEP_GUARD_COMMAND_COMPLETED\nextra output"),
            execution(1, "SLEEP_GUARD_COMMAND_COMPLETED"),
            execution(0, "SLEEP_GUARD_ERROR:1:pmset failed"),
            execution(1, "unrelated -128 text"),
            execution(0, "SLEEP_GUARD_COMMAND_COMPLETED", signalled: true)
        ] {
            guard case .failed = SleepRecovery.classify(result) else {
                preconditionFailure("Ambiguous/failed command treated as successful or cancelled")
            }
        }
    }

    private static func testMergedRequests() {
        let runner = MockRecoveryRunner()
        let recovery = SleepRecovery(timeoutInterval: 1, runnerFactory: { runner })
        var results: [SleepRecoveryResult] = []
        let before = Date()
        for _ in 0..<2 {
            recovery.restore { result in
                precondition(Thread.isMainThread)
                results.append(result)
            }
        }
        waitUntil { runner.startCount == 1 }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.03) {
            runner.resolve(.success(execution(0, "SLEEP_GUARD_COMMAND_COMPLETED")))
        }
        waitUntil { results.count == 2 }
        precondition(runner.startCount == 1 && runner.cancelCount == 0)
        precondition(results.allSatisfy { $0.outcome == .commandCompleted && $0.completedAt >= before && $0.completedAt <= Date() })
        precondition(results[0].completedAt == results[1].completedAt)
    }

    private static func testLaunchFailure() {
        let runner = MockRecoveryRunner()
        let recovery = SleepRecovery(timeoutInterval: 1, runnerFactory: { runner })
        var result: SleepRecoveryResult?
        recovery.restore { result = $0 }
        waitUntil { runner.startCount == 1 }
        runner.resolve(.failure(NSError(domain: "mock", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "simulated launch failure"])))
        waitUntil { result != nil }
        guard case .failed(let reason) = result?.outcome else { preconditionFailure("Launch failure must be reported") }
        precondition(reason.contains("simulated launch failure"))
    }

    private static func testTimeoutAndLateCompletion() {
        let runner = MockRecoveryRunner()
        let recovery = SleepRecovery(timeoutInterval: 0.05, runnerFactory: { runner })
        var results: [SleepRecoveryResult] = []
        recovery.restore { result in precondition(Thread.isMainThread); results.append(result) }
        waitUntil { results.count == 1 }
        precondition(results[0].outcome == .timedOut)
        precondition(runner.startCount == 1 && runner.cancelCount == 1)
        runner.resolve(.success(execution(0, "SLEEP_GUARD_COMMAND_COMPLETED")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(results.count == 1 && results[0].outcome == .timedOut)
        // A fresh user action is allowed after the old operation completes.
        recovery.restore { results.append($0) }
        waitUntil { runner.startCount == 2 }
        runner.resolve(.success(execution(0, "SLEEP_GUARD_AUTH_CANCELLED:-128")))
        waitUntil { results.count == 2 }
        precondition(results[1].outcome == .cancelled)
    }

    private static func testCancellation() {
        let runner = MockRecoveryRunner()
        let recovery = SleepRecovery(timeoutInterval: 1, runnerFactory: { runner })
        var results: [SleepRecoveryResult] = []
        recovery.restore { result in precondition(Thread.isMainThread); results.append(result) }
        waitUntil { runner.startCount == 1 }
        recovery.cancel()
        waitUntil { results.count == 1 }
        precondition(results[0].outcome == .cancelled && runner.cancelCount == 1)
        recovery.cancel() // Idle cancellation is harmless and does not repeat completion.
        runner.resolve(.success(execution(0, "SLEEP_GUARD_COMMAND_COMPLETED")))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(results.count == 1 && runner.cancelCount == 1)
    }

    private static func testPresentationBoundaries() {
        let confirmed = RecoveryPresentation.message(for: .commandCompleted, mode: .allowed)
        precondition(confirmed.contains("已恢复系统休眠") && confirmed.contains("SleepDisabled = 0"))
        for (outcome, mode) in [
            (SleepRecoveryOutcome.commandCompleted, SleepMode.disabled),
            (.commandCompleted, .unknown("模拟未知")),
            (.timedOut, .allowed),
            (.cancelled, .allowed),
            (.failed("模拟失败"), .allowed)
        ] {
            let message = RecoveryPresentation.message(for: outcome, mode: mode)
            precondition(!message.contains("已恢复系统休眠"))
        }
        precondition(RecoveryPresentation.message(for: .timedOut, mode: .allowed).contains("当前允许休眠"))
    }

    private static func testNonblockingPipeRead() {
        let pipe = Pipe()
        let payload = Data("SLEEP_GUARD_COMMAND_COMPLETED\n".utf8)
        pipe.fileHandleForWriting.write(payload)
        // Keep the writer OPEN to simulate an inherited child descriptor. The
        // read must return available bytes without waiting for an EOF.
        let before = Date()
        let actual = try! AdministratorSleepRecoveryRunner.readAvailableOutput(from: pipe.fileHandleForReading)
        precondition(actual == payload && Date().timeIntervalSince(before) < 0.5)
        try! pipe.fileHandleForWriting.close()

        let empty = Pipe()
        precondition(try! AdministratorSleepRecoveryRunner.readAvailableOutput(from: empty.fileHandleForReading).isEmpty)
        try! empty.fileHandleForWriting.close()
    }

    private static func waitUntil(_ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(predicate(), "Asynchronous test deadline exceeded")
    }
}
