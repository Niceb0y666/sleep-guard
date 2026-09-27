import Foundation

/// Only a fresh, post-command reading of zero can confirm recovery.
enum RecoveryPresentation {
    static func message(for outcome: SleepRecoveryOutcome, mode: SleepMode) -> String {
        switch outcome {
        case .commandCompleted:
            switch mode {
            case .allowed:
                return "已恢复系统休眠，确认 SleepDisabled = 0。"
            case .disabled:
                return "恢复未生效：系统仍禁用休眠，未确认恢复。"
            case .unknown(let reason):
                return "恢复命令已执行，但无法确认结果：\(reason)。请点击“马上检测”。"
            }
        case .cancelled:
            return "已取消管理员授权。" + stateDescription(mode)
        case .timedOut:
            return "恢复等待超时，未确认本次操作完成。" + stateDescription(mode) + "请关闭仍显示的授权窗口后重试。"
        case .failed(let reason):
            return "恢复失败：\(reason)。" + stateDescription(mode)
        }
    }

    private static func stateDescription(_ mode: SleepMode) -> String {
        switch mode {
        case .allowed: return "最新检测显示系统当前允许休眠。"
        case .disabled: return "最新检测显示系统仍禁用休眠。"
        case .unknown(let reason): return "无法确认当前设置：\(reason)。"
        }
    }
}
