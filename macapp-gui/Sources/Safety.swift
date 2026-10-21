import AppKit
import Foundation

/// 路径安全校验。所有删除动作必须先过这里，规则与命令行版保持一致。
enum Safety {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static let protectedPaths: Set<String> = [
        "/", "/System", "/usr", "/bin", "/sbin", "/etc", "/private", "/var",
        "/opt", "/Library", "/Applications", "/Users", "/Volumes", "/cores", "/dev",
        home,
        "\(home)/Library",
        "\(home)/Library/Application Support",
        "\(home)/Library/Caches",
        "\(home)/Library/Preferences",
        "\(home)/Library/Logs",
        "\(home)/Library/Containers",
        "\(home)/Library/Group Containers",
        "\(home)/Library/Saved Application State",
        "\(home)/Library/HTTPStorages",
        "\(home)/Library/WebKit",
        "\(home)/Library/Cookies",
        "\(home)/Library/LaunchAgents",
        "\(home)/Library/Application Scripts",
        "\(home)/Library/PreferencePanes",
        "\(home)/Library/QuickLook",
        "\(home)/Library/Services",
        "\(home)/Library/Internet Plug-Ins",
        "\(home)/Library/Spotlight",
        "\(home)/Library/Address Book Plug-Ins",
        "\(home)/Applications",
        "\(home)/.Trash",
        "\(home)/.macapp"
    ]

    static let forbiddenSubtrees: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private", "/var", "/opt",
        "/Library/Apple", "/Library/Extensions", "/Library/Frameworks",
        "\(home)/Documents", "\(home)/Desktop", "\(home)/Downloads",
        "\(home)/Pictures", "\(home)/Music", "\(home)/Movies",
        "\(home)/Library/Keychains", "\(home)/Library/Mobile Documents",
        "\(home)/Library/CloudStorage", "\(home)/Library/Mail",
        "\(home)/Library/Messages", "\(home)/Library/Safari",
        "\(home)/Library/Accounts", "\(home)/.ssh", "\(home)/.gnupg",
        "\(home)/.config"
    ]

    static let allowedRoots: [String] = [
        "/Applications",
        "\(home)/Applications",
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences",
        "/Library/Logs", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Receipts", "/Library/Fonts",
        "\(home)/Library/Application Support",
        "\(home)/Library/Caches",
        "\(home)/Library/Preferences",
        "\(home)/Library/Preferences/ByHost",
        "\(home)/Library/Logs",
        "\(home)/Library/Containers",
        "\(home)/Library/Group Containers",
        "\(home)/Library/Saved Application State",
        "\(home)/Library/HTTPStorages",
        "\(home)/Library/WebKit",
        "\(home)/Library/Cookies",
        "\(home)/Library/LaunchAgents",
        "\(home)/Library/Application Scripts",
        "\(home)/Library/PreferencePanes",
        "\(home)/Library/QuickLook",
        "\(home)/Library/Services",
        "\(home)/Library/Internet Plug-Ins",
        "\(home)/Library/Spotlight",
        "\(home)/Library/Address Book Plug-Ins",
        "\(home)/Library/Fonts"
    ]

    static func normalize(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func check(_ rawPath: String) -> (ok: Bool, reason: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.contains("\0"), !expanded.contains("\n") else {
            return (false, "路径非法")
        }
        guard expanded.contains("..") == false else {
            return (false, "路径包含 .. 片段")
        }
        let path = (expanded as NSString).standardizingPath
        guard path.hasPrefix("/") else { return (false, "必须是绝对路径") }
        guard !protectedPaths.contains(path) else { return (false, "受保护的目录本身不可删除") }

        for forbidden in forbiddenSubtrees where path == forbidden || path.hasPrefix(forbidden + "/") {
            return (false, "位于禁区 \(forbidden)")
        }

        let inside = allowedRoots.contains { path.hasPrefix($0 + "/") }
        guard inside else { return (false, "不在允许操作的目录内") }

        // 符号链接：允许删除链接本身，但指向禁区则拒绝
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let resolved = (dest as NSString).standardizingPath
            let real = resolved.hasPrefix("/") ? resolved : (path as NSString).deletingLastPathComponent + "/" + resolved
            for forbidden in forbiddenSubtrees where real == forbidden || real.hasPrefix(forbidden + "/") {
                return (false, "符号链接指向禁区 \(forbidden)")
            }
        }

        return (true, "")
    }

    /// 删除该项是否需要管理员权限（看父目录是否可写）
    static func needsAdmin(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.hasPrefix("/Library/") { return true }
        return !FileManager.default.isWritableFile(atPath: parent)
    }

    // MARK: - 完全磁盘访问权限

    enum PermissionState: Equatable {
        case granted
        case denied
        case unknown

        var isBlocking: Bool { self == .denied }
    }

    /// 真正需要完全磁盘访问权限才能读的位置。
    /// 注意：旧版用的 `~/Library/Application Support/com.apple.TCC/TCC.db` 在新系统上已经不存在，
    /// 拿它当探针会导致「怎么授权都显示未授权」，这里改用实际受 TCC 保护的应用数据目录。
    private static let permissionProbes: [String] = [
        "\(home)/Library/Containers/com.apple.Safari/Data",
        "\(home)/Library/Safari/History.db",
        "\(home)/Library/Mail",
        "\(home)/Library/Containers/com.apple.mail/Data",
        "\(home)/Library/Messages",
        "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
        "/Library/Application Support/com.apple.TCC/TCC.db"
    ]

    /// 三态探测：能读到任意一个受保护位置 → 已授权；都读不到但确实存在 → 被拦；都不存在 → 无法判断。
    static func permissionState() -> PermissionState {
        var sawProtectedButDenied = false
        let fm = FileManager.default
        for probe in permissionProbes {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: probe, isDirectory: &isDirectory) else { continue }
            let readable: Bool
            if isDirectory.boolValue {
                readable = (try? fm.contentsOfDirectory(atPath: probe)) != nil
            } else {
                readable = FileHandle(forReadingAtPath: probe).map { handle in
                    try? handle.close()
                    return true
                } ?? false
            }
            if readable { return .granted }
            sawProtectedButDenied = true
        }
        return sawProtectedButDenied ? .denied : .unknown
    }

    /// 兼容旧调用点
    static var hasFullDiskAccess: Bool { permissionState() == .granted }

    /// 是否被系统「应用传送」到随机只读路径（直接从 DMG / 压缩包里双击运行）。
    /// 这种情况下每次启动路径都不一样，授权永远留不住。
    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    static var appBundlePath: String { Bundle.main.bundlePath }

    /// 在访达中选中本应用，方便直接拖进「完全磁盘访问权限」列表
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appBundlePath)])
    }

    /// 授权后必须重启进程，TCC 的判定是按进程缓存的，重新探测同一个进程永远还是拒绝。
    static func relaunch() {
        let path = appBundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
    }

    /// 沙盒容器属于其他应用，系统会拦截，必须靠完全磁盘访问权限
    static func isForeignContainer(_ path: String) -> Bool {
        path.hasPrefix("\(home)/Library/Containers/") || path.hasPrefix("\(home)/Library/Group Containers/")
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        if let url { NSWorkspace.shared.open(url) }
    }

    // MARK: - 用户自己创建的本地文件

    /// 应用可能留下「用户文档」的位置。默认这些是禁区，只有在这里显式放行，
    /// 而且只允许删它下面的一级条目，绝不允许删目录本身。
    static let localFileRoots: [String] = [
        "\(home)/Documents",
        "\(home)/Desktop",
        "\(home)/Downloads",
        "\(home)/Movies",
        "\(home)/Music",
        "\(home)/Pictures"
    ]

    /// 本地文件专用校验：比普通校验更严，只放行 `~/Documents/xxx` 这种一级条目。
    static func checkLocalFile(_ rawPath: String) -> (ok: Bool, reason: String) {
        let expanded = (rawPath as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.contains("\0"), !expanded.contains("\n") else {
            return (false, "路径非法")
        }
        guard !expanded.contains("..") else { return (false, "路径包含 .. 片段") }
        let path = (expanded as NSString).standardizingPath
        guard path.hasPrefix("/") else { return (false, "必须是绝对路径") }

        guard let root = localFileRoots.first(where: { path.hasPrefix($0 + "/") }) else {
            return (false, "不在用户文件夹内")
        }
        let rest = String(path.dropFirst(root.count + 1))
        guard !rest.isEmpty, !rest.contains("/") else {
            return (false, "只处理用户文件夹下的一级条目")
        }
        guard rest != ".DS_Store" else { return (false, "系统文件") }

        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let resolved = (dest as NSString).standardizingPath
            let real = resolved.hasPrefix("/") ? resolved : root + "/" + resolved
            for forbidden in forbiddenSubtrees where real == forbidden || real.hasPrefix(forbidden + "/") {
                return (false, "符号链接指向禁区 \(forbidden)")
            }
        }
        return (true, "")
    }
}
