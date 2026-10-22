import Foundation

/// 无界面自检：`MacApp --selftest`，用于编译后快速验证引擎是否正常。
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func expect(_ name: String, _ got: Bool, _ want: Bool) {
        if got == want {
            passed += 1
        } else {
            failed += 1
            print("  FAIL \(name) 期望 \(want) 实际 \(got)")
        }
    }

    /// `--orphans [all]`：把扫描结果全部打印出来，方便人工核对误报
    static func dumpOrphans(includeMedium: Bool) {
        if CommandLine.arguments.contains("--debug-roots") {
            let roots = [
                "Containers", "Group Containers", "Application Support", "Caches",
                "HTTPStorages", "WebKit", "Saved Application State", "Logs",
                "LaunchAgents", "Preferences"
            ]
            for name in roots {
                let path = "\(Safety.home)/Library/\(name)"
                do {
                    let entries = try FileManager.default.contentsOfDirectory(atPath: path)
                    print("  \(name): \(entries.count) 项")
                } catch {
                    print("  \(name): 读取失败 \(error.localizedDescription)")
                }
            }
        }
        let items = OrphanScanner.scan(includeMedium: includeMedium)
            .sorted {
                if $0.category != $1.category { return $0.category < $1.category }
                if $0.confidence != $1.confidence { return $0.confidence == .high }
                return $0.size > $1.size
            }
        var category = ""
        var total: Int64 = 0
        for item in items {
            if item.category != category {
                category = item.category
                print("\n[\(category)]")
            }
            total += item.size
            let size = ByteFormat.string(item.size)
            let padded = String(repeating: " ", count: max(0, 10 - size.count)) + size
            print("  \(item.confidence.label)  \(padded)  \(item.shortPath)")
        }
        print("\n共 \(items.count) 项，\(ByteFormat.string(total))")
    }

    /// `--recommend`：打印每个应用的画像与推荐分数，用于调阈值和人工核对
    static func dumpRecommend() {
        var apps = Scanner.discoverApps()
        for index in apps.indices { Scanner.enrich(&apps[index]) }
        let total = apps.reduce(0) { $0 + $1.footprint }
        let disk = Scanner.diskInfo()
        let context = RecommendationEngine.Context(
            totalFootprint: total, diskCapacity: disk.capacity, diskFree: disk.free
        )
        let now = Date()

        print("应用 \(apps.count) 个，总占用 \(ByteFormat.string(total))，磁盘 \(ByteFormat.string(disk.capacity))\n")
        print("分数  等级      本体      数据      缓存      最后使用        来源       名称")
        print(String(repeating: "-", count: 104))

        let rows = apps.map { app -> (AppInfo, Recommendation) in
            (app, RecommendationEngine.evaluate(app, context: context, now: now))
        }.sorted {
            if $0.1.score != $1.1.score { return $0.1.score > $1.1.score }
            return $0.0.footprint > $1.0.footprint
        }

        for (app, rec) in rows {
            let score = String(format: "%4d", rec.score)
            let level = rec.level.label.padding(toLength: 8, withPad: " ", startingAt: 0)
            let size = ByteFormat.string(app.size).padding(toLength: 9, withPad: " ", startingAt: 0)
            let data = ByteFormat.string(app.dataSize).padding(toLength: 9, withPad: " ", startingAt: 0)
            let cache = ByteFormat.string(app.cacheSize).padding(toLength: 9, withPad: " ", startingAt: 0)
            let used = RecommendationEngine.usageText(app, now: now)
                .padding(toLength: 15, withPad: " ", startingAt: 0)
            let source = app.usageSource.label.padding(toLength: 10, withPad: " ", startingAt: 0)
            print("\(score)  \(level)\(size)\(data)\(cache)\(used)\(source)\(app.name)\(app.isSystem ? " [系统]" : "")")
            if !rec.reasons.isEmpty && rec.isRecommendation {
                print("      ↳ \(rec.reasons.joined(separator: " · "))")
            }
        }

        let recommended = rows.filter { $0.1.isRecommendation }
        print("\n推荐 \(recommended.count) 个，可释放 "
            + "\(ByteFormat.string(recommended.reduce(0) { $0 + $1.0.footprint }))")
    }

    static func run() {
        let home = Safety.home
        print("== 路径安全校验 ==")
        let cases: [(String, Bool)] = [
            ("/System/Library/CoreServices/Finder.app", false),
            ("/usr/bin/python3", false),
            ("/bin/sh", false),
            ("/etc/hosts", false),
            ("\(home)/Documents/foo", false),
            ("\(home)/Downloads/bar", false),
            ("\(home)/Library", false),
            ("\(home)/Library/Caches", false),
            ("\(home)/Library/Application Support", false),
            ("/Applications", false),
            (home, false),
            ("/tmp/whatever", false),
            ("\(home)/Library/../Documents/x", false),
            ("\(home)/.ssh/id_rsa", false),
            ("\(home)/Library/Caches/com.example.app", true),
            ("\(home)/Library/Application Support/Example", true),
            ("\(home)/Library/Containers/com.example.app", true),
            ("/Applications/Example.app", true),
            ("/Library/LaunchDaemons/com.example.plist", true)
        ]
        for (path, want) in cases {
            let result = Safety.check(path)
            expect(path.replacingOccurrences(of: home, with: "~"), result.ok, want)
        }

        print("== 通配符匹配 ==")
        expect("前缀匹配", Scanner.wildcardMatch("com.foo*", "com.foo.bar"), true)
        expect("不匹配", Scanner.wildcardMatch("com.foo*", "com.bar.foo"), false)
        expect("精确匹配", Scanner.wildcardMatch("com.foo", "com.foo"), true)

        print("== 应用发现 ==")
        let apps = Scanner.discoverApps()
        print("  发现 \(apps.count) 个应用")
        expect("至少发现一个应用", apps.count > 0, true)

        print("== 扫描冒烟 ==")
        for app in apps.prefix(3) {
            let plan = Scanner.scan(app, includeLow: true)
            print("  \(app.name) \(app.version) [\(app.bundleID)] \(ByteFormat.string(plan.totalSize)) \(plan.items.count) 项")
            for item in plan.allItems.prefix(4) {
                print("    · \(item.label) \(ByteFormat.string(item.size)) \(item.shortPath)")
            }
            let bad = plan.items.filter { !Safety.check($0.path).ok }
            expect("\(app.name) 扫描结果全部合法", bad.isEmpty, true)
        }

        print("== 废纸篓 ==")
        print("  可写: \(Trasher.isTrashWritable())")

        print("== 移入与还原往返 ==")
        let sandbox = "\(home)/Library/Caches/macapp_gui_selftest"
        let fm = FileManager.default
        try? fm.removeItem(atPath: sandbox)
        try? fm.createDirectory(atPath: sandbox, withIntermediateDirectories: true)
        let payload = "\(sandbox)/payload.txt"
        try? "hello".write(toFile: payload, atomically: true, encoding: .utf8)

        var trashedPath = ""
        do {
            trashedPath = try Trasher.trash(payload)
            expect("原路径已消失", fm.fileExists(atPath: payload), false)
            expect("废纸篓中存在", fm.fileExists(atPath: trashedPath), true)
        } catch {
            expect("移入废纸篓", false, true)
            print("    错误: \(error.localizedDescription)")
        }

        if !trashedPath.isEmpty {
            do {
                try fm.moveItem(atPath: trashedPath, toPath: payload)
                let content = (try? String(contentsOfFile: payload, encoding: .utf8)) ?? ""
                expect("已还原", fm.fileExists(atPath: payload), true)
                expect("内容未损坏", content == "hello", true)
            } catch {
                expect("还原", false, true)
                print("    错误: \(error.localizedDescription)")
            }
        }
        try? fm.removeItem(atPath: sandbox)

        print("== 彻底删除 ==")
        let permDir = "\(home)/Library/Caches/macapp_gui_permtest"
        try? fm.removeItem(atPath: permDir)
        try? fm.createDirectory(atPath: permDir, withIntermediateDirectories: true)
        let permFile = "\(permDir)/gone.txt"
        try? "bye".write(toFile: permFile, atomically: true, encoding: .utf8)
        do {
            try Trasher.deletePermanently(permFile)
            expect("文件已彻底删除", fm.fileExists(atPath: permFile), false)
            let leftover = (try? fm.contentsOfDirectory(atPath: Trasher.trashDir))?
                .filter { $0.contains("gone") } ?? []
            expect("没有残留在废纸篓", leftover.isEmpty, true)
        } catch {
            expect("彻底删除", false, true)
            print("    错误: \(error.localizedDescription)")
        }
        try? fm.removeItem(atPath: permDir)

        var rejected = false
        do {
            try Trasher.deletePermanently("\(home)/Documents/macapp_should_not_exist.txt")
        } catch {
            rejected = true
        }
        expect("禁区路径被拒绝", rejected, true)

        print("== 残留判定 ==")
        let installed: Set<String> = ["com.tencent.xinwechat", "com.apple.Safari"]
        expect("精确命中已装应用", OrphanScanner.belongsToInstalledApp("com.tencent.xinwechat", bundleIDs: installed), true)
        expect("厂商父级目录不误杀", OrphanScanner.belongsToInstalledApp("com.tencent", bundleIDs: installed), true)
        expect("子组件不误杀", OrphanScanner.belongsToInstalledApp("com.tencent.xinwechat.helper", bundleIDs: installed), true)
        expect("孤儿判为残留", OrphanScanner.belongsToInstalledApp("com.youku.mac", bundleIDs: installed), false)
        expect("com.apple 一律排除", OrphanScanner.isSystemKey("com.apple.finder"), true)
        expect("systemgroup 排除", OrphanScanner.isSystemKey("systemgroup.com.apple.configurationprofiles"), true)
        expect("icloud 排除", OrphanScanner.isSystemKey("iCloud.com.foo"), true)
        expect("普通目录名不排除", OrphanScanner.isSystemKey("LarkShell"), false)
        expect("名称模糊命中已装应用", OrphanScanner.nameMatchesInstalledApp("微信", names: [OrphanScanner.normalize("微信")]), true)
        expect("名称完全不沾边", OrphanScanner.nameMatchesInstalledApp("LarkShell", names: ["wechat"]), false)
        expect("同厂商兄弟组件降级",
               OrphanScanner.isVendorSibling("com.google.GoogleUpdater", bundleIDs: ["com.google.Chrome"]), true)
        expect("不同厂商不算兄弟",
               OrphanScanner.isVendorSibling("com.youku.mac", bundleIDs: ["com.google.Chrome"]), false)
        expect("两段目录不算兄弟",
               OrphanScanner.isVendorSibling("com.tencent", bundleIDs: ["com.tencent.workbuddy.mac"]), false)
        expect("自己的偏好设置排除", OrphanScanner.isSystemKey("com.macapp.gui"), true)

        print("== 残留扫描冒烟 ==")
        let highOnly = OrphanScanner.scan(includeMedium: false)
        let everything = OrphanScanner.scan(includeMedium: true)
        print("  高置信度 \(highOnly.count) 项 / 含中置信度 \(everything.count) 项，合计 \(ByteFormat.string(everything.reduce(0) { $0 + $1.size }))")
        for item in everything.prefix(14) {
            print("    · [\(item.confidence.label)] \(item.category) \(ByteFormat.string(item.size)) \(item.shortPath)")
        }
        expect("残留结果全部通过安全校验", everything.allSatisfy { Safety.check($0.path).ok }, true)
        expect("高置信度默认勾选", highOnly.allSatisfy { $0.selected }, true)
        expect("中置信度默认不勾选", everything.filter { $0.confidence == .medium }.allSatisfy { !$0.selected }, true)
        expect("不含系统目录", everything.contains { OrphanScanner.isSystemKey($0.name) }, false)
        expect("不含已装应用的目录", everything.contains { item in
            apps.contains { !$0.bundleID.isEmpty && item.name.lowercased() == $0.bundleID.lowercased() }
        }, false)

        print("== 本地文件 ==")
        let localCases: [(String, Bool)] = [
            ("\(home)/Documents/微信文件", true),
            ("\(home)/Documents/抖音下载", true),
            ("\(home)/Documents", false),
            ("\(home)/Documents/foo/bar", false),
            ("\(home)/Documents/../.ssh/id_rsa", false),
            ("\(home)/Documents/.DS_Store", false),
            ("\(home)/Library/Caches/x", false),
            ("/tmp/x", false)
        ]
        for (path, want) in localCases {
            let result = Safety.checkLocalFile(path)
            expect(path.replacingOccurrences(of: home, with: "~"), result.ok, want)
        }
        expect("中文名前缀命中", Scanner.matchesLocalName("抖音下载", tokens: ["抖音"]), true)
        expect("英文名前缀命中", Scanner.matchesLocalName("larksuite-notes", tokens: ["lark"]), true)
        expect("词中间不算命中", Scanner.matchesLocalName("Clark", tokens: ["lark"]), false)
        expect("无关名字不命中", Scanner.matchesLocalName("工作周报", tokens: ["抖音"]), false)

        print("== 权限探测 ==")
        let state = Safety.permissionState()
        print("  permissionState = \(state)，isTranslocated = \(Safety.isTranslocated)")
        expect("权限状态可判定", state == .granted || state == .denied || state == .unknown, true)
        expect("探测至少看到一个受保护位置", state != .unknown, true)

        print("== 本地文件扫描冒烟 ==")
        for app in apps {
            let found = Scanner.localFiles(for: app)
            expect("\(app.name) 本地文件默认不勾选", found.allSatisfy { !$0.selected }, true)
            expect("\(app.name) 本地文件全部通过校验", found.allSatisfy { Safety.checkLocalFile($0.path).ok }, true)
            guard !found.isEmpty else { continue }
            print("  \(app.name)：\(found.count) 项 \(ByteFormat.string(found.reduce(0) { $0 + $1.size }))")
            for item in found.prefix(3) {
                print("    · \(item.shortPath)")
            }
        }

        print("== 容器前缀归一 ==")
        expect("团队 ID 被去掉",
               OrphanScanner.stripContainerPrefix("5A4RE8SF68.com.tencent.xinWeChat") == "com.tencent.xinWeChat", true)
        expect("group 前缀被去掉",
               OrphanScanner.stripContainerPrefix("group.com.tencent.xinWeChat") == "com.tencent.xinWeChat", true)
        expect("Apple 共享容器识别",
               OrphanScanner.stripContainerPrefix("243LU875E5.groups.com.apple.podcasts") == "com.apple.podcasts", true)
        expect("普通名字不受影响",
               OrphanScanner.stripContainerPrefix("LarkShell") == "LarkShell", true)

        print("== 全盘应用索引 ==")
        let index = Scanner.installedIndex()
        let plain = Scanner.discoverApps()
        print("  /Applications 里 \(plain.count) 个，全盘索引 \(index.bundleIDs.count) 个 bundle id")
        expect("索引不少于常规扫描", index.bundleIDs.count >= plain.count, true)
        expect("索引里没有空 id", index.bundleIDs.contains(""), false)
        for id in plain.compactMap({ $0.bundleID.isEmpty ? nil : $0.bundleID.lowercased() }) {
            expect("常规应用 \(id) 在索引里", index.bundleIDs.contains(id), true)
        }

        print("== 合成残留识别 ==")
        let fakeRoot = "\(home)/Library/Caches"
        let fakeName = "com.example.selftest.orphan"
        let fakePath = "\(fakeRoot)/\(fakeName)"
        try? fm.removeItem(atPath: fakePath)
        try? fm.createDirectory(atPath: fakePath, withIntermediateDirectories: true)
        try? "x".write(toFile: "\(fakePath)/a.txt", atomically: true, encoding: .utf8)
        let found = OrphanScanner.scan(includeMedium: true)
        expect("自造的孤儿目录能被扫出来", found.contains { $0.path == fakePath }, true)
        expect("自造的孤儿默认勾选", found.first { $0.path == fakePath }?.selected ?? false, true)
        try? fm.removeItem(atPath: fakePath)

        print("== 推荐引擎 ==")
        let now = Date()
        func makeApp(
            _ name: String, size: Int64 = 0, data: Int64 = 0, cache: Int64 = 0,
            days: Int? = nil, system: Bool = false, source: UsageSource = .spotlight
        ) -> AppInfo {
            var app = AppInfo(path: "/Applications/\(name).app", name: name,
                              bundleID: "com.test.\(name)", version: "1.0")
            app.size = size
            app.dataSize = data
            app.cacheSize = cache
            app.lastUsed = days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) }
            app.usageSource = days == nil ? .unknown : source
            app.isSystem = system
            return app
        }

        // 系统软件永远不推荐，哪怕又大又旧
        let systemApp = makeApp("SystemHog", size: 6_000_000_000, cache: 9_000_000_000, days: 900, system: true)
        expect("系统软件不推荐卸载", RecommendationEngine.evaluate(systemApp, now: now).level == .keep, true)

        // 一年没用 + 本体 1.5 GB
        let stale = makeApp("Stale", size: 1_500_000_000, days: 400)
        expect("一年没用且不小 → 强烈推荐", RecommendationEngine.evaluate(stale, now: now).level == .strong, true)

        // 昨天刚用过，体积大但缓存正常
        let fresh = makeApp("Fresh", size: 3_000_000_000, cache: 200_000_000, days: 1)
        expect("最近用过 → 不推荐", RecommendationEngine.evaluate(fresh, now: now).level == .keep, true)

        // 最近用过但缓存 6 GB，仍然该提示
        let freshFat = makeApp("FreshFat", size: 100_000_000, cache: 6_000_000_000, days: 2)
        expect("最近用过但缓存巨大 → 仍然推荐", RecommendationEngine.evaluate(freshFat, now: now).isRecommendation, true)

        // 三个月没用 + 1.2 GB 缓存
        let cacheHeavy = makeApp("CacheHeavy", size: 50_000_000, cache: 1_200_000_000, days: 100)
        let cacheRec = RecommendationEngine.evaluate(cacheHeavy, now: now)
        expect("缓存过 GB 会进理由", cacheRec.reasons.contains { $0.contains("缓存") }, true)
        expect("缓存过大要推荐", cacheRec.isRecommendation, true)

        // 只有安装时间，不能当作「没用过」
        let installOnly = makeApp("InstallOnly", size: 100_000_000, days: 900, source: .install)
        expect("仅安装时间不参与判断", RecommendationEngine.evaluate(installOnly, now: now).level == .keep, true)

        // 完全没有使用记录
        let noRecord = makeApp("NoRecord", size: 3_000_000_000, days: nil)
        expect("没有使用记录不硬判", RecommendationEngine.evaluate(noRecord, now: now).level == .keep, true)

        // 数据比本体大很多
        let bloated = makeApp("Bloated", size: 200_000_000, data: 4_000_000_000, days: 200)
        expect("数据是本体 20 倍会被指出",
               RecommendationEngine.evaluate(bloated, now: now).reasons.contains { $0.contains("倍") }, true)

        expect("天数换算", RecommendationEngine.daysSince(now.addingTimeInterval(-86_400 * 10), now: now) == 10, true)
        expect("空时间不换算", RecommendationEngine.daysSince(nil, now: now) == nil, true)

        print("== 占比与格式 ==")
        var shareApp = AppInfo(path: "/Applications/X.app", name: "X", bundleID: "com.test.x", version: "1")
        shareApp.size = 250
        shareApp.dataSize = 250
        expect("footprint 是三者之和", shareApp.footprint == 500, true)
        expect("占比计算", abs(shareApp.share(of: 1000) - 0.5) < 0.0001, true)
        expect("分母为零不崩", shareApp.share(of: 0) == 0, true)
        expect("磁盘占比", abs(shareApp.shareOfDisk(2000) - 0.25) < 0.0001, true)
        expect("百分比 50%", ByteFormat.percent(0.5) == "50%", true)
        expect("极小占比用小于号", ByteFormat.percent(0.000001) == "<0.1%", true)
        expect("零占比", ByteFormat.percent(0) == "0%", true)

        print("== 系统软件识别 ==")
        expect("bundle id 前缀判定",
               Scanner.isSystemApp(path: "/Applications/Foo.app", bundleID: "com.apple.Foo", appleSigned: false), true)
        expect("普通第三方不误判",
               Scanner.isSystemApp(path: "/Applications/Chrome.app", bundleID: "com.google.Chrome", appleSigned: false), false)
        expect("Apple 签名也算系统组件",
               Scanner.isSystemApp(path: "/Applications/Somewhere.app", bundleID: "com.other.app", appleSigned: true), true)
        expect("/System 路径判定",
               Scanner.isSystemApp(path: "/System/Applications/Notes.app", bundleID: "", appleSigned: false), true)
        if FileManager.default.fileExists(atPath: "/Applications/Safari.app") {
            // Safari 是符号链接，指向 /System/Cryptexes/...，只看字面路径会漏
            expect("Safari 解析链接后算系统软件",
                   Scanner.isSystemApp(path: "/Applications/Safari.app", bundleID: "com.apple.Safari", appleSigned: true), true)
        }
        if FileManager.default.fileExists(atPath: "/System/Applications/Notes.app") {
            expect("真实系统应用 Apple 签名",
                   Scanner.appleSigned("/System/Applications/Notes.app"), true)
        }

        print("== 应用画像 ==")
        let disk = Scanner.diskInfo()
        print("  磁盘 \(ByteFormat.string(disk.capacity))，可用 \(ByteFormat.string(disk.free))")
        expect("磁盘容量可读", disk.capacity > 0, true)
        expect("可用空间不超过总量", disk.free <= disk.capacity, true)

        var probe = Array(Scanner.discoverApps().prefix(8))
        for index in probe.indices { Scanner.enrich(&probe[index]) }
        for app in probe {
            let used = RecommendationEngine.usageText(app)
            print("  \(app.name) 本体 \(ByteFormat.string(app.size)) 数据 \(ByteFormat.string(app.dataSize)) "
                + "缓存 \(ByteFormat.string(app.cacheSize)) \(used) [\(app.usageSource.label)] "
                + (app.isSystem ? "系统" : "自装"))
        }
        expect("footprint 不小于本体", probe.allSatisfy { $0.footprint >= $0.size }, true)
        expect("使用时间与来源一致",
               probe.allSatisfy { ($0.lastUsed == nil) == ($0.usageSource == .unknown) }, true)
        expect("画像后占比在 0~1 之间",
               probe.allSatisfy { app in
                   let total = probe.reduce(0) { $0 + $1.footprint }
                   let ratio = app.share(of: total)
                   return ratio >= 0 && ratio <= 1
               }, true)

        print("== 系统 / 自装分组 ==")
        var allApps = Scanner.discoverApps()
        for index in allApps.indices { Scanner.enrich(&allApps[index]) }
        let systemCount = allApps.filter { $0.isSystem }.count
        let userCount = allApps.count - systemCount
        print("  系统软件 \(systemCount) 个 / 自装软件 \(userCount) 个")
        expect("能识别出系统软件", systemCount > 0, true)
        expect("不会全部判成系统", userCount > 0, true)
        expect("系统软件不含可卸载的第三方",
               allApps.filter { $0.isSystem && $0.path.hasPrefix("/Applications/") && !$0.bundleID.hasPrefix("com.apple.") }
                   .allSatisfy { Scanner.appleSigned($0.path) }, true)

        print("")
        print("通过 \(passed) 项，失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }
}
