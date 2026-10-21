import Foundation

enum Trasher {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let trashDir = "\(home)/.Trash"
    static let baseDir = "\(home)/.macapp"
    static let historyDir = "\(baseDir)/history"

    static func isTrashWritable() -> Bool {
        let probe = "\(trashDir)/.macapp-probe-\(getpid())"
        do {
            try Data().write(to: URL(fileURLWithPath: probe))
            try FileManager.default.removeItem(atPath: probe)
            return true
        } catch {
            return false
        }
    }

    /// 用系统 API 移入废纸篓：支持 Finder「放回原处」，比手动 mv 更可靠。
    static func trash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: &resulting
        )
        return (resulting as URL?)?.path ?? "\(trashDir)/\((path as NSString).lastPathComponent)"
    }

    /// 彻底删除，不进废纸篓。调用前必须已过 Safety.check 与用户二次确认。
    static func deletePermanently(_ path: String) throws {
        let check = Safety.check(path)
        guard check.ok else {
            throw NSError(
                domain: "macapp", code: 403,
                userInfo: [NSLocalizedDescriptionKey: "拒绝操作 \(path)：\(check.reason)"]
            )
        }
        try FileManager.default.removeItem(atPath: path)
    }

    /// 以管理员权限删除系统级残留（/Library 下的守护进程、特权助手等）。
    static func deleteAsAdmin(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        for path in paths {
            let check = Safety.check(path)
            guard check.ok else {
                throw NSError(
                    domain: "macapp", code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "拒绝操作 \(path)：\(check.reason)"]
                )
            }
        }
        let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        try runAdmin("/bin/rm -rf -- \(quoted)")
    }

    /// 清理安装包收据，避免 pkgutil 里留下孤儿记录。
    static func forgetReceipt(_ pkgID: String) {
        guard !pkgID.isEmpty else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        task.arguments = ["--forget", pkgID]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            try? runAdmin("/usr/sbin/pkgutil --forget '\(pkgID.replacingOccurrences(of: "'", with: "'\\''"))'")
        }
    }

    private static func runAdmin(_ command: String) throws {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "授权被拒绝或执行失败"
            throw NSError(
                domain: "macapp", code: 401,
                userInfo: [NSLocalizedDescriptionKey: message.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
    }

    static func save(_ record: UninstallRecord) throws {
        try FileManager.default.createDirectory(
            atPath: historyDir,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: URL(fileURLWithPath: "\(historyDir)/\(record.id).json"))
    }

    static func loadAll() -> [UninstallRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: historyDir) else { return [] }
        let decoder = JSONDecoder()
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted(by: >)
            .compactMap { name in
                guard let data = FileManager.default.contents(atPath: "\(historyDir)/\(name)") else { return nil }
                return try? decoder.decode(UninstallRecord.self, from: data)
            }
    }

    static func load(_ id: String) -> UninstallRecord? {
        guard let data = FileManager.default.contents(atPath: "\(historyDir)/\(id).json") else { return nil }
        return try? JSONDecoder().decode(UninstallRecord.self, from: data)
    }

    struct RestoreSummary {
        var restored = 0
        var skipped = 0
        var errors: [String] = []
    }

    static func restore(_ id: String) throws -> RestoreSummary {
        guard var record = load(id) else { throw NSError(domain: "macapp", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到会话 \(id)"]) }
        guard !record.isPermanent else {
            throw NSError(domain: "macapp", code: 410, userInfo: [NSLocalizedDescriptionKey: "这条记录是彻底删除，没有可还原的副本"])
        }
        var summary = RestoreSummary()

        for entry in record.items.reversed() {
            let fm = FileManager.default
            if fm.fileExists(atPath: entry.original) {
                summary.skipped += 1
                summary.errors.append("原位置已存在，跳过：\(entry.original)")
                continue
            }
            guard fm.fileExists(atPath: entry.trashed) else {
                summary.errors.append("废纸篓中已不存在：\(entry.trashed)")
                continue
            }
            do {
                let parent = (entry.original as NSString).deletingLastPathComponent
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: entry.trashed, toPath: entry.original)
                summary.restored += 1
            } catch {
                summary.errors.append("还原失败 \(entry.original)：\(error.localizedDescription)")
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        record.restored_at = formatter.string(from: Date())
        try? save(record)
        return summary
    }

    static func newID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
