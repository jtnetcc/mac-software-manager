import AppKit
import Foundation

enum OrphanConfidence: String, Codable {
    case high
    case medium

    var label: String { self == .high ? "高" : "中" }
}

struct OrphanItem: Identifiable, Hashable {
    let path: String
    let name: String
    let category: String
    let size: Int64
    let confidence: OrphanConfidence
    var selected: Bool

    var id: String { path }

    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// 扫描"应用已经不在，但数据还留着"的孤儿目录。
///
/// 判定原则：宁可漏报，不可错杀。
/// · 名字是 bundle id 的目录，只有精确匹配不到任何已装应用才算孤儿（高置信）
/// · 名字是自然语言的应用数据/缓存目录，只能模糊匹配（中置信，默认不选中）
/// · 所有 com.apple.* 与已知系统目录一律排除
enum OrphanScanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// 系统自带、绝不能当成残留的目录名
    private static let systemNames: Set<String> = [
        "clouddocs", "mobilesync", "knowledge", "addressbook", "callhistorydb",
        "callhistorytransactions", "differentialprivacy", "fileprovider",
        "intelligenceflow", "facetime", "animoji", "diskimages", "crashreporter",
        "dock", "siriactions", "coresimulator", "homekit", "identityservices",
        "apple", "appstore", "appledouble", "windowserver", "com.apple",
        "icloud", "com.apple.icloud", "caches", "logs", "preferences",
        "byhost", "diagnosticreports", "homebrew", "webkit", "unrealengine",
        // 这些是 macOS 自己的组件，名字不带反向域名，靠名字会误判
        "geoservices", "passkit", "gamekit", "familycircled", "askpermissiond",
        "diagnostics_agent", "localizationswitcherd", "mbuseragent", "sesstorage",
        "networkserviceproxy", "icdd", "photosupgrade.aapbz", "photossearch.aapbz",
        "disc recording.log", "discrecording.log", "fsck_hfs.log", "amsdatamigratortool",
        "apmexperimentsuitename", "apmanalyticssuitename", "installation",
        "sentrycrash", "io.sentry", "kscrash", "sceneunderstandingd",
        // Apple 自家带团队 ID 的共享容器，去掉前缀后剩下的名字
        "tvappservices.container", "is.workflow.my.app", "is.workflow.shortcuts",
        "com.apple.podcasts", "com.apple.tv", "cloudkit", "com.apple.CloudKit"
    ]

    /// 不是应用，但删了会带来麻烦或纯属误报的公共目录
    private static let keepKeys: Set<String> = [
        "org.swift.swiftpm", "org.cocoapods", "com.github.wasilibs",
        "swiftpm", "clang", "org.llvm.clang", "com.llvm.clang",
        "com.macapp.gui"   // 本应用自己的偏好设置
    ]

    private struct Job {
        let root: String
        let category: String
        let stripExtension: Bool
        let stripSuffix: String?
        let forceMedium: Bool
    }

    private static let jobs: [Job] = [
        Job(root: "\(home)/Library/Containers", category: "沙盒容器", stripExtension: false, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/Group Containers", category: "共享容器", stripExtension: false, stripSuffix: nil, forceMedium: true),
        Job(root: "\(home)/Library/Application Support", category: "应用数据", stripExtension: false, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/Caches", category: "缓存", stripExtension: false, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/HTTPStorages", category: "网络存储", stripExtension: false, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/WebKit", category: "WebKit 数据", stripExtension: false, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/Saved Application State", category: "窗口状态", stripExtension: false, stripSuffix: ".savedState", forceMedium: false),
        Job(root: "\(home)/Library/Logs", category: "日志", stripExtension: false, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/LaunchAgents", category: "登录项", stripExtension: true, stripSuffix: nil, forceMedium: false),
        Job(root: "\(home)/Library/Preferences", category: "偏好设置", stripExtension: true, stripSuffix: nil, forceMedium: false)
    ]

    static func scan(includeMedium: Bool) -> [OrphanItem] {
        let fm = FileManager.default
        let index = Scanner.installedIndex()
        let bundleIDs = index.bundleIDs

        var names = Set<String>()
        for name in index.names {
            let normalized = normalize(name)
            if !normalized.isEmpty { names.insert(normalized) }
            // 「Visual Studio Code」这类长名字，目录常常只用其中一个词
            for token in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let part = normalize(String(token))
                if part.count >= 4 { names.insert(part) }
            }
        }
        for id in bundleIDs {
            // bundle id 的第二段就是厂商名，com.bytedance.xxx 对应 ~/Library/Caches/Bytedance
            let parts = id.split(separator: ".")
            if parts.count >= 2 {
                let vendor = normalize(String(parts[1]))
                if vendor.count >= 4 { names.insert(vendor) }
            }
        }

        var results: [OrphanItem] = []

        for job in jobs {
            guard let entries = try? fm.contentsOfDirectory(atPath: job.root) else { continue }
            let debug = CommandLine.arguments.contains("--debug-roots")
            var skippedSystem = 0, skippedNotExist = 0, skippedKnown = 0, skippedZero = 0, added = 0
            for entry in entries {
                if entry.hasPrefix(".") { continue }

                var key = entry
                if job.stripExtension { key = (key as NSString).deletingPathExtension }
                if let suffix = job.stripSuffix, key.hasSuffix(suffix) {
                    key = String(key.dropLast(suffix.count))
                }
                key = stripContainerPrefix(key)

                if isSystemKey(key) { skippedSystem += 1; continue }

                let path = job.root + "/" + entry
                guard fm.fileExists(atPath: path) else { skippedNotExist += 1; continue }

                let dotCount = key.filter { $0 == "." }.count
                let looksLikeBundleID = dotCount > 0 && !key.contains(" ")
                var confidence: OrphanConfidence = .high
                var orphan: Bool

                if looksLikeBundleID {
                    orphan = !belongsToInstalledApp(key, bundleIDs: bundleIDs)
                    // 只有三段以上的反向域名才够可信。com.foo 这种两段可能只是厂商共享目录，
                    // default.store 这类普通文件名也会被误判，一律降为中置信度。
                    if dotCount < 2 { confidence = .medium }
                    if job.forceMedium { confidence = .medium }
                    // 装着 com.google.Chrome 时，com.google.GoogleUpdater 这种同厂商兄弟组件
                    // 很可能还在服役（更新器、插件），降为中置信度，交给用户判断。
                    if orphan && isVendorSibling(key, bundleIDs: bundleIDs) { confidence = .medium }
                } else {
                    orphan = !nameMatchesInstalledApp(key, names: names)
                    confidence = .medium
                }

                guard orphan else { skippedKnown += 1; continue }

                let size = Scanner.size(of: path)
                if size == 0 { skippedZero += 1; continue }

                // 大容器几乎不可能是死数据——真卸载干净的容器通常只有几十 KB。
                // 超过 200 MB 一律降为中置信度，不默认勾选，逼用户自己确认。
                if size >= 200 * 1024 * 1024 { confidence = .medium }
                if confidence == .medium && !includeMedium { continue }
                added += 1

                results.append(OrphanItem(
                    path: path,
                    name: key,
                    category: job.category,
                    size: size,
                    confidence: confidence,
                    selected: confidence == .high
                ))
            }
            if debug {
                print("  [debug] \(job.category) 共 \(entries.count) 项 → 系统 \(skippedSystem) / 不存在 \(skippedNotExist) / 已装 \(skippedKnown) / 空 \(skippedZero) / 收录 \(added)")
            }
        }

        return results.sorted {
            if $0.confidence != $1.confidence { return $0.confidence == .high }
            return $0.size > $1.size
        }
    }

    // MARK: - 判定

    /// 去掉 Group Container 的团队 ID 与 group 前缀。
    /// 不去的话，`5A4RE8SF68.com.tencent.xinWeChat`（微信）和
    /// `243LU875E5.groups.com.apple.podcasts`（Apple）都会被当成孤儿——
    /// 这正是 12 GB 微信数据被误删的直接原因。
    static func stripContainerPrefix(_ raw: String) -> String {
        var key = raw
        if let range = key.range(of: "^[A-Z0-9]{10}\\.", options: .regularExpression) {
            key.removeSubrange(range)
        }
        for prefix in ["group.", "groups."] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        return key
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func isSystemKey(_ key: String) -> Bool {
        let k = key.lowercased()
        if k.hasPrefix("com.apple") || k.hasPrefix("group.com.apple") { return true }
        if k.hasPrefix("systemgroup.") { return true }
        if k.hasPrefix("icloud.") { return true }
        if keepKeys.contains(k) { return true }
        return systemNames.contains(k)
    }

    /// 目录名是否是某个已装应用的"自己、父级共享目录或子级组件"
    static func belongsToInstalledApp(_ key: String, bundleIDs: Set<String>) -> Bool {
        let k = key.lowercased()
        if bundleIDs.contains(k) { return true }
        for id in bundleIDs {
            if id.hasPrefix(k + ".") { return true }   // 这是已装应用的厂商共享目录
            if k.hasPrefix(id + ".") { return true }   // 这是已装应用的子组件
        }
        return false
    }

    /// 同厂商的兄弟组件：装着 `com.google.Chrome`，`com.google.GoogleUpdater` 就不太可能是纯垃圾
    static func isVendorSibling(_ key: String, bundleIDs: Set<String>) -> Bool {
        let k = key.lowercased()
        let parts = k.split(separator: ".")
        guard parts.count >= 3 else { return false }
        let vendor = parts.prefix(2).joined(separator: ".")
        for id in bundleIDs where id != k {
            let idParts = id.split(separator: ".")
            if idParts.count >= 3, idParts.prefix(2).joined(separator: ".") == vendor {
                return true
            }
        }
        return false
    }

    static func nameMatchesInstalledApp(_ key: String, names: Set<String>) -> Bool {
        let k = normalize(key)
        guard !k.isEmpty else { return true }
        if names.contains(k) { return true }
        guard k.count >= 4 else { return false }
        for name in names where name.count >= 4 {
            if name.hasPrefix(k) || k.hasPrefix(name) { return true }
        }
        return false
    }
}
