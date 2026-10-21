import Foundation

enum InstallKind: String {
    case app = "应用程序"
    case dmg = "磁盘映像"
    case zip = "压缩包"
    case pkg = "安装包"
}

struct InstallCandidate {
    let sourceURL: URL
    let kind: InstallKind
    let appName: String
    let appPath: String
    let version: String
    let bundleID: String
    let size: Int64
    let mountPoint: String?
    let tempDir: String?
}

enum InstallError: LocalizedError {
    case unsupported(String)
    case noAppFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "暂不支持 .\(ext) 格式"
        case .noAppFound: return "没有在镜像或压缩包里找到可安装的应用"
        case .failed(let message): return message
        }
    }
}

enum Installer {
    static let destinations = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"]

    static func analyze(_ url: URL) throws -> InstallCandidate {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "app":
            return candidate(forAppAt: url.path, source: url, kind: .app, mount: nil, temp: nil)
        case "dmg":
            let mount = try mountDMG(url)
            guard let appPath = firstApp(in: mount) else {
                detach(mount)
                throw InstallError.noAppFound
            }
            return candidate(forAppAt: appPath, source: url, kind: .dmg, mount: mount, temp: nil)
        case "zip":
            let temp = try extractZip(url)
            guard let appPath = firstApp(in: temp) else {
                try? FileManager.default.removeItem(atPath: temp)
                throw InstallError.noAppFound
            }
            return candidate(forAppAt: appPath, source: url, kind: .zip, mount: nil, temp: temp)
        case "pkg", "mpkg":
            return InstallCandidate(
                sourceURL: url, kind: .pkg, appName: url.deletingPathExtension().lastPathComponent,
                appPath: "", version: "", bundleID: "", size: Scanner.size(of: url.path),
                mountPoint: nil, tempDir: nil
            )
        default:
            throw InstallError.unsupported(ext)
        }
    }

    static func release(_ candidate: InstallCandidate) {
        if let mount = candidate.mountPoint { detach(mount) }
        if let temp = candidate.tempDir { try? FileManager.default.removeItem(atPath: temp) }
    }

    static func install(_ candidate: InstallCandidate, to destination: String) throws -> String {
        if candidate.kind == .pkg {
            try installPkg(candidate.sourceURL)
            return "已通过系统安装器安装 \(candidate.sourceURL.lastPathComponent)"
        }

        let name = (candidate.appPath as NSString).lastPathComponent
        let target = destination + "/" + name
        let fm = FileManager.default

        try fm.createDirectory(atPath: destination, withIntermediateDirectories: true)

        if fm.fileExists(atPath: target) {
            _ = try? Trasher.trash(target)
        }

        guard let output = Scanner.run("/usr/bin/ditto", [candidate.appPath, target]) else {
            throw InstallError.failed("复制失败")
        }
        _ = output
        guard fm.fileExists(atPath: target) else {
            throw InstallError.failed("复制后目标不存在，可能被系统拦截")
        }
        return target
    }

    static func installPkg(_ url: URL) throws {
        let script = "do shell script \"/usr/sbin/installer -pkg \(shellQuote(url.path)) -target /\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "安装器返回错误"
            throw InstallError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - 内部

    private static func candidate(
        forAppAt path: String, source: URL, kind: InstallKind, mount: String?, temp: String?
    ) -> InstallCandidate {
        let info = Scanner.loadApp(path)
        return InstallCandidate(
            sourceURL: source,
            kind: kind,
            appName: info.name,
            appPath: path,
            version: info.version,
            bundleID: info.bundleID,
            size: Scanner.size(of: path),
            mountPoint: mount,
            tempDir: temp
        )
    }

    private static func firstApp(in dir: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        if let direct = entries.first(where: { $0.hasSuffix(".app") }) {
            return dir + "/" + direct
        }
        for entry in entries {
            let sub = dir + "/" + entry
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue else { continue }
            if let found = firstApp(in: sub) { return found }
        }
        return nil
    }

    private static func mountDMG(_ url: URL) throws -> String {
        guard let output = Scanner.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-plist", url.path]),
              let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let entities = dict["system-entities"] as? [[String: Any]]
        else {
            throw InstallError.failed("挂载磁盘映像失败")
        }
        for entity in entities {
            if let mount = entity["mount-point"] as? String, !mount.isEmpty {
                return mount
            }
        }
        throw InstallError.failed("映像挂载成功但没有找到卷")
    }

    private static func detach(_ mount: String) {
        _ = Scanner.run("/usr/bin/hdiutil", ["detach", mount, "-quiet"])
    }

    private static func extractZip(_ url: URL) throws -> String {
        let temp = NSTemporaryDirectory() + "macapp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        _ = Scanner.run("/usr/bin/ditto", ["-x", "-k", url.path, temp])
        return temp
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
