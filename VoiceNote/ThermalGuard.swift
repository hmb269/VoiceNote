import Foundation

/// 本机计算（本地转写、区分说话人）时控制温度：
/// 手机开始变热就每段之间歇一下；很热就停下来等降温再继续
enum ThermalGuard {
    /// 正在为降温暂停（给界面显示）
    nonisolated(unsafe) static var cooling = false

    static func breathe() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            return
        case .fair:
            Thread.sleep(forTimeInterval: 0.3)
        default:
            cooling = true
            // 等到降回「温」再继续，最多等 3 分钟一轮，避免永远卡住
            let deadline = Date().addingTimeInterval(180)
            while ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                  Date() < deadline {
                Thread.sleep(forTimeInterval: 3)
            }
            cooling = false
        }
    }
}
