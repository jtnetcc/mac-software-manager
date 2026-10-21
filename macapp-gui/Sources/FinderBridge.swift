import AppKit
import Foundation

/// 访达代删通道。
///
/// 其他应用的沙盒容器（`~/Library/Containers/xxx`）受 TCC 保护，本应用没有
/// 「完全磁盘访问权限」时，`removeItem` / `trashItem` 都会被内核拒绝。
/// 访达本身在系统白名单里，由它来删可以绕过这道限制——代价是首次使用时会
/// 弹出一次「允许控制访达」的授权。
enum FinderBridge {
    enum BridgeError: LocalizedError {
        case notAuthorized
        case failed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "没有控制访达的权限，请到「系统设置 → 隐私与安全性 → 自动化」中允许本应用控制「访达」"
            case .failed(let message):
                return message
            case .timeout:
                return "访达响应超时，可能正忙"
            }
        }
    }

    /// 让访达把这些路径移入废纸篓，返回实际已消失的路径。
    @discardableResult
    static func moveToTrash(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { return [] }

        let list = paths.map { "POSIX file \(quote($0))" }.joined(separator: ", ")
        let script = """
        tell application "Finder"
            delete {\(list)}
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw BridgeError.failed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline {
            usleep(100_000)
        }
        if process.isRunning {
            process.terminate()
            throw BridgeError.timeout
        }

        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            if message.contains("-1743") || message.contains("-10004")
                || message.contains("权限违例") || message.contains("not authorized") {
                throw BridgeError.notAuthorized
            }
            throw BridgeError.failed(message.isEmpty ? "访达未能删除" : message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return paths.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    /// 打开废纸篓，方便用户清空
    static func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Trasher.trashDir))
    }

    private static func quote(_ text: String) -> String {
        "\"" + text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
