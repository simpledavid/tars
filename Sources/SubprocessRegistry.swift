import Foundation

/// 跟踪所有由 ClaudeCodeClient / CodexClient spawn 出来的子进程。
///
/// 为什么需要：单次 stream 取消时 `continuation.onTermination` 会 terminate 进程，
/// 但 **App 整体退出** 时 stream 不会自然 finish，subprocess 可能变成僵尸继续跑。
/// AppDelegate.applicationWillTerminate 调 `terminateAll()` 兜底。
///
/// 使用：spawn Process 后立即 `register(p)`，进程退出 / 取消后 `unregister(p)`
final class SubprocessRegistry: @unchecked Sendable {
    static let shared = SubprocessRegistry()

    private let lock = NSLock()
    private var processes: Set<ObjectIdentifier> = []
    private var refs: [ObjectIdentifier: Process] = [:]   // 持有 reference 防止 ARC 提前释放

    private init() {}

    func register(_ p: Process) {
        let id = ObjectIdentifier(p)
        lock.lock()
        processes.insert(id)
        refs[id] = p
        lock.unlock()
    }

    func unregister(_ p: Process) {
        let id = ObjectIdentifier(p)
        lock.lock()
        processes.remove(id)
        refs.removeValue(forKey: id)
        lock.unlock()
    }

    /// App 退出时遍历杀掉所有还活着的子进程。
    /// 调用方：AppDelegate.applicationWillTerminate
    func terminateAll() {
        lock.lock()
        let toKill = Array(refs.values)
        refs.removeAll()
        processes.removeAll()
        lock.unlock()

        for p in toKill where p.isRunning {
            p.terminate()
        }
    }

    var runningCount: Int {
        lock.lock(); defer { lock.unlock() }
        return processes.count
    }
}
