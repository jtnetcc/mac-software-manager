import Foundation

struct RuleTemplate: Codable {
    let path: String
    let kind: String?
    let confidence: String
    let label: String
    let privileged: Bool?
}

struct RuleGlob: Codable {
    let pattern: String
    let kind: String?
    let confidence: String
    let label: String
    let privileged: Bool?
}

struct Rules: Codable {
    let templates: [RuleTemplate]
    let globs: [RuleGlob]
    let keepConfigLabels: [String]

    enum CodingKeys: String, CodingKey {
        case templates, globs
        case keepConfigLabels = "keep_config_labels"
    }

    static let empty = Rules(templates: [], globs: [], keepConfigLabels: [])
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let appRoots = ["/Applications", "\(home)/Applications"]

    // MARK: - 规则加载

    static func loadRules() -> Rules {
        var candidates: [URL] = []
        if let url = Bundle.main.url(forResource: "rules", withExtension: "json") {
            candidates.append(url)
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("rules.json"))
        candidates.append(exeDir.appendingPathComponent("Resources/rules.json"))

        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let rules = try? JSONDecoder().decode(Rules.self, from: data) {
                return rules
            }
        }
        return .empty
    }

    // MARK: - 应用发现

    static func discoverApps() -> [AppInfo] {
        var seen = Set<String>()
        var results: [AppInfo] = []

        for root in appRoots {
            let rootURL = URL(fileURLWithPath: root)
            guard FileManager.default.fileExists(atPath: root) else { continue }
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let en = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: nil
            ) else { continue }

            for case let url as URL in en {
                if url.pathExtension.lowercased() == "app" {
                    en.skipDescendants()
                    let path = url.path
                    // 别把自己列进可卸载清单，卸载自己没有任何意义
                    if path == Safety.appBundlePath { continue }
                    if !seen.contains(path) {
                        seen.insert(path)
                        results.append(loadApp(path))
                    }
                }
            }
        }

        // 别把自己列进可卸载清单（不管是当前运行的副本还是 /Applications 里那份）
        let ownID = Bundle.main.bundleIdentifier
        return results
            .filter { ownID == nil || $0.bundleID != ownID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func loadApp(_ path: String) -> AppInfo {
        var info: [String: Any] = [:]
        let infoPath = path + "/Contents/Info.plist"
        if let data = FileManager.default.contents(atPath: infoPath),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
           let dict = plist as? [String: Any] {
            info = dict
        }
        let fallbackName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? fallbackName
        return AppInfo(
            path: path,
            name: name,
            bundleID: (info["CFBundleIdentifier"] as? String) ?? "",
            version: (info["CFBundleShortVersionString"] as? String) ?? ""
        )
    }

    // MARK: - 体积

    static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }

        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if let en = fm.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil) {
            for case let fileURL as URL in en {
                guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
                if values.isRegularFile == true {
                    total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                }
            }
        }
        return total
    }

    // MARK: - 全盘应用索引

    /// 已安装应用索引：bundle id 集合 + 名称集合。
    ///
    /// **必须用 Spotlight 全盘找，不能只看 /Applications。**
    /// 真实事故：微信装在 `~/Library/Mobile Documents/.../WeChat.app`（iCloud 里），
    /// 只扫两个目录就认为"微信没装"，于是它 12 GB 的容器被判成残留删掉了。
    static func installedIndex() -> (bundleIDs: Set<String>, names: Set<String>) {
        var bundleIDs = Set<String>()
        var names = Set<String>()

        func absorb(path: String) {
            let url = URL(fileURLWithPath: path)
            let file = url.deletingPathExtension().lastPathComponent
            if !file.isEmpty { names.insert(file.lowercased()) }
            let infoPath = path + "/Contents/Info.plist"
            guard let data = FileManager.default.contents(atPath: infoPath),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any] else { return }
            if let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty {
                bundleIDs.insert(id.lowercased())
            }
            for key in ["CFBundleName", "CFBundleDisplayName"] {
                if let name = dict[key] as? String, !name.isEmpty { names.insert(name.lowercased()) }
            }
            if let exe = dict["CFBundleExecutable"] as? String, !exe.isEmpty {
                names.insert(exe.lowercased())
            }
        }

        for app in discoverApps() {
            if !app.bundleID.isEmpty { bundleIDs.insert(app.bundleID.lowercased()) }
            names.insert(app.name.lowercased())
            absorb(path: app.path)
        }

        // Spotlight 索引里的所有 .app，包含装在 iCloud、Documents、任意目录的
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") {
                let path = String(line)
                guard path.hasSuffix(".app"), !path.hasPrefix("/Volumes/") else { continue }
                absorb(path: path)
            }
        } catch {
            // 拿不到 Spotlight 也不致命，退回只认 /Applications
        }

        return (bundleIDs, names)
    }

    // MARK: - 残留扫描

    static func scan(_ app: AppInfo, includeLow: Bool) -> ScanPlan {
        let rules = loadRules()
        var buckets: [String: ResidueItem] = [:]
        var notes: [String] = []

        func add(_ item: ResidueItem?) {
            guard let item else { return }
            if item.path == app.path || item.path.hasPrefix(app.path + "/") { return }
            let key = (item.path as NSString).resolvingSymlinksInPath
            if let existing = buckets[key] {
                if item.confidence < existing.confidence {
                    buckets[key] = ResidueItem(
                        path: existing.path, label: existing.label, confidence: item.confidence,
                        size: existing.size, privileged: existing.privileged, selected: existing.selected
                    )
                }
                return
            }
            buckets[key] = item
        }

        let ctx: [String: String] = [
            "name": app.name,
            "bundle_name": app.name,
            "bundle_id": app.bundleID
        ]

        for tpl in rules.templates {
            if tpl.path.contains("{bundle_id}") && app.bundleID.isEmpty { continue }
            guard let filled = fill(tpl.path, ctx) else { continue }
            add(makeItem(
                filled,
                label: tpl.label,
                confidence: Confidence(rawValue: tpl.confidence) ?? .medium
            ))
        }

        for glob in rules.globs {
            if glob.pattern.contains("{bundle_id}") && app.bundleID.isEmpty { continue }
            guard let filled = fill(glob.pattern, ctx) else { continue }
            for hit in expandGlob(filled) {
                add(makeItem(hit, label: glob.label, confidence: Confidence(rawValue: glob.confidence) ?? .medium))
            }
        }

        if includeLow {
            for path in groupContainers(app) {
                add(makeItem(path, label: "共享容器", confidence: .low))
            }
            for path in fuzzyDirs(app) {
                add(makeItem(path, label: "疑似数据目录", confidence: .low))
            }
        }

        let (pkgItems, pkgNotes) = pkgResidues(app)
        for item in pkgItems { add(item) }
        notes.append(contentsOf: pkgNotes)

        var items = Array(buckets.values).sorted { $0.size > $1.size }

        var privileged: [ResidueItem] = []
        var clean: [ResidueItem] = []
        for item in items {
            let result = Safety.check(item.path)
            if !result.ok {
                notes.append("受保护，不会删除（\(result.reason)）：\(item.path)")
                continue
            }
            if item.privileged {
                privileged.append(item)
            } else {
                clean.append(item)
            }
        }
        items = clean

        if !app.bundleID.isEmpty, let pkg = pkgID(for: app.path) {
            notes.append("安装包收据：\(pkg)（卸载后可执行 pkgutil --forget \(pkg) 清理）")
        }

        let appItem = ResidueItem(
            path: app.path,
            label: "应用程序",
            confidence: .high,
            size: app.size > 0 ? app.size : size(of: app.path),
            privileged: Safety.needsAdmin(app.path),
            selected: true
        )

        return ScanPlan(
            app: app,
            appItem: appItem,
            items: items,
            privileged: privileged,
            notes: notes,
            localFiles: localFiles(for: app)
        )
    }

    // MARK: - 用户自己创建的本地文件

    /// 应用在 `~/Documents`、`~/Desktop`、`~/Downloads` 等位置留下的东西。
    /// 只负责列出来，默认不勾选，删除时也只允许移入废纸篓。
    static func localFiles(for app: AppInfo) -> [ResidueItem] {
        let fm = FileManager.default
        var tokens = Set<String>()

        func addToken(_ text: String) {
            let t = text.lowercased().trimmingCharacters(in: .whitespaces)
            guard t.count >= 2 else { return }
            // 纯英文的短词太容易误伤（比如 App 名 "Zy"），要求至少 4 个字符
            if t.allSatisfy({ $0.isASCII }) && t.count < 4 { return }
            tokens.insert(t)
        }

        addToken(app.name)
        addToken(URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent)
        addToken(executableName(app.path))
        if !app.bundleID.isEmpty {
            addToken(app.bundleID)
            let parts = app.bundleID.split(separator: ".")
            if parts.count >= 2 { addToken(String(parts[1])) }
        }
        for suffix in ["免费版", "专业版", "客户端", "桌面版", "企业版"] where app.name.hasSuffix(suffix) {
            addToken(String(app.name.dropLast(suffix.count)))
        }
        guard !tokens.isEmpty else { return [] }

        // 安装包不是应用留下的数据，别混进来
        let installerExtensions: Set<String> = [
            "dmg", "pkg", "zip", "apk", "exe", "msi", "tar", "gz", "xz", "7z", "iso", "crx", "rar"
        ]

        var results: [ResidueItem] = []
        for root in Safety.localFileRoots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                let ext = (entry as NSString).pathExtension.lowercased()
                if installerExtensions.contains(ext) { continue }
                let path = root + "/" + entry
                guard matchesLocalName(entry, tokens: tokens) else { continue }
                guard Safety.checkLocalFile(path).ok else { continue }
                let size = size(of: path)
                if size == 0 { continue }
                results.append(ResidueItem(
                    path: path,
                    label: (root as NSString).lastPathComponent,
                    confidence: .medium,
                    size: size,
                    privileged: false,
                    local: true,
                    selected: false
                ))
            }
        }
        return results.sorted { $0.size > $1.size }
    }

    /// 可执行文件名常常是英文（红果免费短剧 → hongguo-desktop-companion），能补上中文名匹配不到的目录
    static func executableName(_ appPath: String) -> String {
        let infoPath = appPath + "/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: infoPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let exe = dict["CFBundleExecutable"] as? String,
              exe.lowercased() != "electron"
        else { return "" }
        return exe
    }

    static func matchesLocalName(_ entry: String, tokens: Set<String>) -> Bool {
        let lower = entry.lowercased()
        let parts = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        for token in tokens {
            if lower == token { return true }
            if lower.hasPrefix(token + ".") || lower.hasPrefix(token + " ")
                || lower.hasPrefix(token + "-") || lower.hasPrefix(token + "_") { return true }
            for part in parts {
                if part == token { return true }
                // lark → Larksuite / lark_notes；中文没有分词，前缀命中即可
                if part.hasPrefix(token) && part.count <= token.count + 8 { return true }
            }
        }
        return false
    }

    // MARK: - 辅助

    static func fill(_ pattern: String, _ ctx: [String: String]) -> String? {
        var result = pattern
        for (key, value) in ctx {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        if result.contains("{") || result.contains("}") { return nil }
        return (result as NSString).expandingTildeInPath
    }

    static func makeItem(_ path: String, label: String, confidence: Confidence) -> ResidueItem? {
        let standardized = (path as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: standardized)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: standardized)) != nil
        else { return nil }
        return ResidueItem(
            path: standardized,
            label: label,
            confidence: confidence,
            size: size(of: standardized),
            privileged: Safety.needsAdmin(standardized)
        )
    }

    /// 支持 `*` 的简易 glob：只在最后一级目录内枚举匹配。
    static func expandGlob(_ pattern: String) -> [String] {
        let ns = pattern as NSString
        let dir = ns.deletingLastPathComponent
        let name = ns.lastPathComponent
        guard name.contains("*") || name.contains("?") else {
            return FileManager.default.fileExists(atPath: pattern) ? [pattern] : []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { wildcardMatch(name, $0) }.map { dir + "/" + $0 }
    }

    static func wildcardMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0, ti = 0
        var starIndex = -1
        var matchIndex = 0

        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starIndex = pi
                matchIndex = ti
                pi += 1
            } else if starIndex != -1 {
                pi = starIndex + 1
                matchIndex += 1
                ti = matchIndex
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func groupContainers(_ app: AppInfo) -> [String] {
        let root = "\(home)/Library/Group Containers"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let bid = app.bundleID.lowercased()
        let token = app.name.lowercased().filter { $0.isLetter || $0.isNumber }
        var hits: [String] = []
        for entry in entries {
            let low = entry.lowercased()
            let flat = low.filter { $0.isLetter || $0.isNumber }
            var matched = false
            if !bid.isEmpty && low.hasPrefix(bid + ".") { matched = true }
            else if !token.isEmpty && token.count >= 4 && flat.contains(token) { matched = true }
            if matched { hits.append(root + "/" + entry) }
        }
        return hits
    }

    static func fuzzyDirs(_ app: AppInfo) -> [String] {
        let token = app.name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard token.count >= 4 else { return [] }
        var hits: [String] = []
        for root in ["\(home)/Library/Application Support", "\(home)/Library/Caches"] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let flat = entry.lowercased().filter { $0.isLetter || $0.isNumber }
                guard flat.count >= 4 else { continue }
                if flat.hasPrefix(token) || token.hasPrefix(flat) {
                    hits.append(root + "/" + entry)
                }
            }
        }
        return hits
    }

    static func pkgID(for path: String) -> String? {
        guard let output = run("/usr/sbin/pkgutil", ["--file-info", path]) else { return nil }
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pkgid:") {
                let value = trimmed.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func pkgResidues(_ app: AppInfo) -> ([ResidueItem], [String]) {
        guard let pkg = pkgID(for: app.path) else { return ([], []) }
        guard let output = run("/usr/sbin/pkgutil", ["--files", pkg]) else { return ([], []) }

        var items: [ResidueItem] = []
        var notes: [String] = []
        for line in output.split(separator: "\n") {
            var path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, path != "." else { continue }
            if !path.hasPrefix("/") { path = "/" + path }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if path == app.path || path.hasPrefix(app.path + "/") { continue }
            let check = Safety.check(path)
            if !check.ok {
                notes.append("安装包文件不在可操作范围（\(check.reason)）：\(path)")
                continue
            }
            if let item = makeItem(path, label: "安装包文件", confidence: .high) {
                items.append(item)
            }
        }
        return (items, notes)
    }

    static func run(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
