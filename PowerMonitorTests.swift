import Foundation

@main
struct PowerMonitorTests {
    static func main() {
        let cases: [(String, SleepMode)] = [
            ("System-wide power settings:\n SleepDisabled 0\n", .allowed),
            (" SleepDisabled 1\n", .disabled),
            ("\tSleepDisabled = false\r\n", .allowed),
            ("SleepDisabled: TRUE", .disabled),
            ("SleepDisabled 0\nSleepDisabled false", .allowed),
            ("SleepDisabled 1\nSleepDisabled true", .disabled)
        ]
        for (output, expected) in cases {
            precondition(PowerMonitor.parse(output) == expected, "Incorrect result for \(output)")
        }
        for output in ["", "sleep 1", "SleepDisabled 2", "SleepDisabled", "SleepDisabled 0 trailing", "SleepDisabledFuture 0", "SleepDisabled 0\nSleepDisabled 1"] {
            guard case .unknown = PowerMonitor.parse(output) else {
                preconditionFailure("Unknown input treated as a known state: \(output)")
            }
        }
        print("PowerMonitor parser: 13 cases passed")
    }
}
