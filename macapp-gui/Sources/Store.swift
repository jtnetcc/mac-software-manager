import AppKit
import Foundation
import SwiftUI

enum ViewMode: String, Hashable {
    case apps
    case recommend
    case orphans
}

struct AlertPayload: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var isError: Bool = false
}

struct ResultPayload: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var recordID: String?
    var isError: Bool = false
    var needsPermission: Bool = false
    var showTrashButton: Bool = false
}

/// 是否是系统权限拦截（而非路径校验失败或磁盘错误）
func isPermissionError(_ error: Error) -> Bool {
    let text = error.localizedDescription
    if text.contains("拒绝操作") { return false }
    return text.contains("许可")
        || text.contains("permission")
        || text.contains("Operation not permitted")
        || text.contains("不允许")
        || text.contains("未能将")
}

/// 受 TCC 保护的文件交给访达处理，返回成功清掉的项数
@discardableResult
func rescueWithFinder(
    _ items: [ResidueItem],
    suffix: String,
    record: inout UninstallRecord,
    total: inout Int64
) -> Int {
    guard !items.isEmpty else { return 0 }
    do {
        let moved = try FinderBridge.moveToTrash(items.map { $0.path })
        var rescued = 0
        for item in items {
            if moved.contains(item.path) {
                record.items.append(TrashedEntry(
                    original: item.path, trashed: "", size: item.size, label: item.label + suffix
                ))
                total += item.size
                rescued += 1
            } else {
                record.errors.append("\(item.path)：系统保护，访达也未能删除")
            }
        }
        return rescued
    } catch {
        for item in items {
            record.errors.append("\(item.path)：\(error.localizedDescription)")
        }
        return 0
    }
}

final class Store: ObservableObject {
    @Published var apps: [AppInfo] = []
    @Published var selectedID: String?
    @Published var plan: ScanPlan?
    @Published var searchText = ""
    @Published var includeLow = false
    @Published var isBusy = false
    @Published var status = "正在读取应用列表…"
    @Published var history: [UninstallRecord] = []
    @Published var pendingUninstall = false
    @Published var pendingPermanent = false
    @Published var permission = Safety.permissionState()

    var hasFullDiskAccess: Bool { permission == .granted }

    @Published var mode: ViewMode = .apps
    @Published var showOrphans = false
    @Published var orphans: [OrphanItem] = []
    @Published var isScanningOrphans = false
    @Published var includeMediumOrphans = false
    @Published var orphanScanned = false
    @Published var pendingOrphanDelete = false
    @Published var result: ResultPayload?
    @Published var installCandidate: InstallCandidate?
    @Published var alert: AlertPayload?

    /// 防止旧的一次扫描结果覆盖新结果
    private var orphanScanToken = 0
    /// 同上，应用列表也有两阶段刷新
    private var scanToken = 0

    var filteredApps: [AppInfo] {
        guard !searchText.isEmpty else { return apps }
        let query = searchText.lowercased()
        return apps.filter {
            $0.name.lowercased().contains(query) || $0.bundleID.lowercased().contains(query)
        }
    }

    /// 侧边栏分组：自己装的在前，系统自带的在后
    var userApps: [AppInfo] { filteredApps.filter { !$0.isSystem } }
    var systemApps: [AppInfo] { filteredApps.filter { $0.isSystem } }

    var userTotalSize: Int64 { userApps.reduce(0) { $0 + $1.footprint } }
    var systemTotalSize: Int64 { systemApps.reduce(0) { $0 + $1.footprint } }
    /// 所有应用的占用总和，占比的分母
    var totalFootprint: Int64 { apps.reduce(0) { $0 + $1.footprint } }

    var diskCapacity: Int64 { Scanner.diskInfo().capacity }
    var diskFree: Int64 { Scanner.diskInfo().free }

    var recommendationContext: RecommendationEngine.Context {
        RecommendationEngine.Context(
            totalFootprint: totalFootprint,
            diskCapacity: diskCapacity,
            diskFree: diskFree
        )
    }

    func recommendation(for app: AppInfo) -> Recommendation {
        RecommendationEngine.evaluate(app, context: recommendationContext)
    }

    /// 推荐清单，按分数从高到低
    var recommendedApps: [(app: AppInfo, rec: Recommendation)] {
        let context = recommendationContext
        return apps
            .compactMap { app -> (app: AppInfo, rec: Recommendation)? in
                let rec = RecommendationEngine.evaluate(app, context: context)
                return rec.isRecommendation ? (app, rec) : nil
            }
            .sorted {
                if $0.rec.score != $1.rec.score { return $0.rec.score > $1.rec.score }
                return $0.app.footprint > $1.app.footprint
            }
    }

    var recommendedBytes: Int64 { recommendedApps.reduce(0) { $0 + $1.app.footprint } }
    var recommendedCacheBytes: Int64 { recommendedApps.reduce(0) { $0 + $1.app.cacheSize } }

    var selectedApp: AppInfo? { apps.first { $0.id == selectedID } }

    // MARK: - 应用列表

    /// 分两阶段：先出体积让界面立刻可用，再在后台补最后使用时间、缓存、系统判定。
    /// 一次性做完要 4~6 秒，期间界面是空的，体验很差。
    func refresh() {
        scanToken += 1
        isBusy = true
        status = "正在扫描已安装应用…"
        let token = scanToken
        DispatchQueue.global(qos: .userInitiated).async {
            var list = Scanner.discoverApps()
            for index in list.indices {
                list[index].size = Scanner.size(of: list[index].path)
            }
            let firstPass = list

            DispatchQueue.main.async {
                guard token == self.scanToken else { return }
                self.apps = firstPass
                self.permission = Safety.permissionState()
                self.status = "正在分析使用记录 0/\(firstPass.count)…"
            }

            var enriched = firstPass
            for index in enriched.indices {
                Scanner.enrich(&enriched[index])
                // 每 25 个推一次进度，既能看到进展又不至于刷爆主线程
                if index % 25 == 24 {
                    let partial = enriched
                    let done = index + 1
                    DispatchQueue.main.async {
                        guard token == self.scanToken else { return }
                        self.apps = partial
                        self.status = "正在分析使用记录 \(done)/\(partial.count)…"
                    }
                }
            }
            let final = enriched

            DispatchQueue.main.async {
                guard token == self.scanToken else { return }
                self.apps = final
                self.isBusy = false
                self.status = "共 \(final.count) 个应用"
                self.permission = Safety.permissionState()
                if let id = self.selectedID, !final.contains(where: { $0.id == id }) {
                    self.selectedID = nil
                    self.plan = nil
                }
            }
        }
    }

    func select(_ id: String) {
        guard let app = apps.first(where: { $0.id == id }) else { return }
        selectedID = id
        plan = nil
        isBusy = true
        status = "正在扫描 \(app.name) 的残留文件…"
        let includeLow = self.includeLow
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = Scanner.scan(app, includeLow: includeLow)
            DispatchQueue.main.async {
                self.plan = scanned
                self.isBusy = false
                self.status = ""
            }
        }
    }

    func rescan() {
        if let id = selectedID { select(id) }
    }

    /// 用户从系统设置授权后回来，手动重新检测
    func recheckPermission() {
        let state = Safety.permissionState()
        permission = state
        if state == .granted {
            alert = AlertPayload(
                title: "权限已生效",
                message: "现在可以直接删除其他应用的沙盒容器了。",
                isError: false
            )
            rescan()
            if mode == .orphans { scanOrphans() }
            return
        }

        alert = AlertPayload(
            title: state == .denied ? "系统仍然拒绝访问" : "无法判断权限状态",
            message: """
            系统设置里需要把「\(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "本应用")」加入「完全磁盘访问权限」列表并打开开关。

            加完请点下面的「重启应用」——TCC 的判定是按进程缓存的，同一个进程里重新检测永远还是拒绝，必须重启才读得到新权限。

            如果重启后依然提示未授权，请确认：
            · 应用在 /Applications 里，不是从 dmg 里直接打开的
            · 列表里那条记录指向的是当前这个应用
            """,
            isError: false
        )
    }

    func relaunchApp() {
        Safety.relaunch()
    }

    func setIncludeLow(_ value: Bool) {
        includeLow = value
        rescan()
    }

    func toggleAll(_ selected: Bool) {
        guard var current = plan else { return }
        for index in current.items.indices { current.items[index].selected = selected }
        plan = current
    }

    // MARK: - 本地文件（用户自己创建的）

    func toggleLocal(_ path: String, _ value: Bool) {
        guard var current = plan,
              let index = current.localFiles.firstIndex(where: { $0.path == path }) else { return }
        current.localFiles[index].selected = value
        plan = current
    }

    func toggleAllLocal(_ selected: Bool) {
        guard var current = plan else { return }
        for index in current.localFiles.indices { current.localFiles[index].selected = selected }
        plan = current
    }

    func revealLocal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - 残留扫描（应用已不在，数据还留着）

    var selectedOrphans: [OrphanItem] { orphans.filter { $0.selected } }

    var selectedOrphanSize: Int64 { selectedOrphans.reduce(0) { $0 + $1.size } }

    var orphanTotalSize: Int64 { orphans.reduce(0) { $0 + $1.size } }

    /// 按分类分组，界面按组展示
    var orphanGroups: [(category: String, items: [OrphanItem])] {
        var order: [String] = []
        var buckets: [String: [OrphanItem]] = [:]
        for item in orphans {
            if buckets[item.category] == nil { order.append(item.category) }
            buckets[item.category, default: []].append(item)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    func switchMode(_ mode: ViewMode) {
        self.mode = mode
        if mode == .orphans && !orphanScanned && !isScanningOrphans {
            scanOrphans()
        }
        // 推荐依赖使用时间与缓存，如果还没扫过画像就先补一次
        if mode == .recommend && apps.isEmpty && !isBusy {
            refresh()
        }
    }

    /// 从推荐页跳到某个应用的卸载清单
    func inspectFromRecommend(_ app: AppInfo) {
        mode = .apps
        select(app.id)
    }

    func scanOrphans() {
        orphanScanToken += 1
        let token = orphanScanToken
        isScanningOrphans = true
        status = "正在扫描残留文件…"
        let includeMedium = includeMediumOrphans

        DispatchQueue.global(qos: .userInitiated).async {
            let found = OrphanScanner.scan(includeMedium: includeMedium)
            DispatchQueue.main.async {
                guard token == self.orphanScanToken else { return }
                self.orphans = found
                self.isScanningOrphans = false
                self.orphanScanned = true
                self.status = ""
                self.permission = Safety.permissionState()
            }
        }
    }

    func setIncludeMediumOrphans(_ value: Bool) {
        includeMediumOrphans = value
        scanOrphans()
    }

    func toggleOrphan(_ path: String, _ value: Bool) {
        guard let index = orphans.firstIndex(where: { $0.path == path }) else { return }
        orphans[index].selected = value
    }

    func toggleAllOrphans(_ selected: Bool) {
        for index in orphans.indices { orphans[index].selected = selected }
    }

    func revealOrphan(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func performOrphanDelete(toTrash: Bool) {
        pendingOrphanDelete = false
        let items = selectedOrphans
        guard !items.isEmpty else { return }

        isBusy = true
        status = toTrash ? "正在把 \(items.count) 项移入废纸篓…" : "正在彻底删除 \(items.count) 项…"

        DispatchQueue.global(qos: .userInitiated).async {
            var record = UninstallRecord(
                id: Trasher.newID(),
                created: Trasher.timestamp(),
                app: toTrash ? "残留文件清理（废纸篓）" : "残留文件清理",
                bundle_id: nil,
                path: nil,
                items: [],
                errors: [],
                total_size: 0,
                restored_at: nil,
                permanent: !toTrash
            )

            var total: Int64 = 0
            var blocked: [OrphanItem] = []
            var permissionBlocked = false

            for item in items {
                let check = Safety.check(item.path)
                guard check.ok else {
                    record.errors.append("拒绝操作 \(item.path)：\(check.reason)")
                    continue
                }
                do {
                    if toTrash {
                        let dest = try Trasher.trash(item.path)
                        record.items.append(TrashedEntry(
                            original: item.path, trashed: dest, size: item.size, label: item.category
                        ))
                    } else {
                        try Trasher.deletePermanently(item.path)
                        record.items.append(TrashedEntry(
                            original: item.path, trashed: "", size: item.size, label: item.category
                        ))
                    }
                    total += item.size
                } catch {
                    if isPermissionError(error) {
                        blocked.append(item)
                        permissionBlocked = true
                    } else {
                        record.errors.append("\(item.path)：\(error.localizedDescription)")
                    }
                }
            }

            var rescued = 0
            if !blocked.isEmpty {
                do {
                    let moved = try FinderBridge.moveToTrash(blocked.map { $0.path })
                    for item in blocked {
                        if moved.contains(item.path) {
                            record.items.append(TrashedEntry(
                                original: item.path, trashed: "", size: item.size,
                                label: item.category + "（访达移入废纸篓）"
                            ))
                            total += item.size
                            rescued += 1
                        } else {
                            record.errors.append("\(item.path)：系统保护，访达也未能删除")
                        }
                    }
                } catch {
                    for item in blocked {
                        record.errors.append("\(item.path)：\(error.localizedDescription)")
                    }
                }
            }

            record.total_size = total
            try? Trasher.save(record)

            DispatchQueue.main.async {
                self.isBusy = false
                self.status = ""

                var message = toTrash
                    ? "已把 \(record.items.count) 项移入废纸篓，共 \(ByteFormat.string(total))。确认没问题后再清空废纸篓。"
                    : "已彻底删除 \(record.items.count) 项，释放 \(ByteFormat.string(total))。此操作不可恢复。"
                if rescued > 0 {
                    message += "\n其中 \(rescued) 项受系统保护，无法直接删除，已由访达移入废纸篓——清空废纸篓即可彻底清除。"
                }
                if !record.errors.isEmpty {
                    message += "\n\(record.errors.count) 项未完成：\n"
                        + record.errors.prefix(3).joined(separator: "\n")
                }
                if permissionBlocked && !self.hasFullDiskAccess {
                    message += "\n\n提示：给本应用授予「完全磁盘访问权限」后重试，可以一次性清干净。"
                }

                self.result = ResultPayload(
                    title: record.items.isEmpty ? "没有清理成功" : (permissionBlocked ? "部分残留被系统拦截" : "清理完成"),
                    message: message,
                    recordID: toTrash ? record.id : nil,
                    isError: record.items.isEmpty,
                    needsPermission: permissionBlocked && !self.hasFullDiskAccess,
                    showTrashButton: rescued > 0 || toTrash
                )

                self.scanOrphans()
            }
        }
    }

    // MARK: - 卸载

    func performUninstall() {
        guard let current = plan else { return }
        pendingUninstall = false

        guard Trasher.isTrashWritable() else {
            alert = AlertPayload(
                title: "废纸篓不可写",
                message: "无法把文件移入废纸篓，已中止，未改动任何文件。\n请到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」为本应用授权后重试。",
                isError: true
            )
            return
        }

        let app = current.app
        let items = current.selectedItems
        let appItem = current.appItem
        let localItems = current.selectedLocalFiles
        isBusy = true
        status = "正在卸载 \(app.name)…"

        DispatchQueue.global(qos: .userInitiated).async {
            var record = UninstallRecord(
                id: Trasher.newID(),
                created: Trasher.timestamp(),
                app: app.name,
                bundle_id: app.bundleID,
                path: app.path,
                items: [],
                errors: [],
                total_size: 0,
                restored_at: nil
            )

            if !app.bundleID.isEmpty,
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
                running.terminate()
                var waited = 0.0
                while !running.isTerminated && waited < 3.0 {
                    usleep(200_000)
                    waited += 0.2
                }
                if !running.isTerminated { running.forceTerminate() }
            }

            var total: Int64 = 0
            var aborted = false
            var blocked: [ResidueItem] = []

            do {
                let dest = try Trasher.trash(appItem.path)
                record.items.append(TrashedEntry(
                    original: appItem.path, trashed: dest, size: appItem.size, label: appItem.label
                ))
                total += appItem.size
            } catch {
                aborted = true
                record.errors.append("应用本体删除失败：\(error.localizedDescription)")
            }

            if !aborted {
                for item in items {
                    let check = Safety.check(item.path)
                    guard check.ok else {
                        record.errors.append("拒绝操作 \(item.path)：\(check.reason)")
                        continue
                    }
                    do {
                        let dest = try Trasher.trash(item.path)
                        record.items.append(TrashedEntry(
                            original: item.path, trashed: dest, size: item.size, label: item.label
                        ))
                        total += item.size
                    } catch {
                        if isPermissionError(error) {
                            blocked.append(item)
                        } else {
                            record.errors.append("\(item.path)：\(error.localizedDescription)")
                        }
                    }
                }
            }

            let rescued = rescueWithFinder(blocked, suffix: "", record: &record, total: &total)

            // 用户自己创建的文件：只走废纸篓，永远不进「彻底删除」通道
            for item in localItems {
                guard Safety.checkLocalFile(item.path).ok else {
                    record.errors.append("拒绝操作 \(item.path)")
                    continue
                }
                do {
                    let dest = try Trasher.trash(item.path)
                    record.items.append(TrashedEntry(
                        original: item.path, trashed: dest, size: item.size,
                        label: "本地文件 · " + item.label
                    ))
                    total += item.size
                } catch {
                    record.errors.append("\(item.path)：\(error.localizedDescription)")
                }
            }

            record.total_size = total
            try? Trasher.save(record)

            DispatchQueue.main.async {
                self.isBusy = false
                self.status = ""
                if aborted {
                    self.result = ResultPayload(
                        title: "卸载中止",
                        message: "应用本体无法移入废纸篓，已停止操作，未触碰任何残留文件。\n\(record.errors.first ?? "")",
                        recordID: nil,
                        isError: true
                    )
                } else {
                    var message = "已移入废纸篓 \(record.items.count) 项，共 \(ByteFormat.string(total))。"
                    if rescued > 0 {
                        message += "\n其中 \(rescued) 项受系统保护，已由访达代为移入废纸篓。"
                    }
                    if !localItems.isEmpty {
                        message += "\n包含 \(localItems.count) 项你勾选的本地文件，同样在废纸篓里，随时能还原。"
                    }
                    if !record.errors.isEmpty {
                        message += "\n\(record.errors.count) 项未完成。"
                    }
                    self.result = ResultPayload(
                        title: "卸载完成",
                        message: message,
                        recordID: record.id,
                        isError: false,
                        showTrashButton: rescued > 0
                    )
                }
                self.plan = nil
                self.selectedID = nil
                self.refresh()
            }
        }
    }

    // MARK: - 彻底删除（不可恢复）

    func performPermanentDelete(includePrivileged: Bool) {
        guard let current = plan else { return }
        pendingPermanent = false

        let app = current.app
        let items = current.selectedItems
        let appItem = current.appItem
        let privileged = includePrivileged ? current.privileged : []
        let localItems = current.selectedLocalFiles

        isBusy = true
        status = "正在彻底删除 \(app.name)…"

        DispatchQueue.global(qos: .userInitiated).async {
            var record = UninstallRecord(
                id: Trasher.newID(),
                created: Trasher.timestamp(),
                app: app.name,
                bundle_id: app.bundleID,
                path: app.path,
                items: [],
                errors: [],
                total_size: 0,
                restored_at: nil,
                permanent: true
            )

            // 收据必须在删包之前查，删完就查不到了
            let pkgID = Scanner.pkgID(for: app.path) ?? ""

            if !app.bundleID.isEmpty,
               let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
                running.terminate()
                var waited = 0.0
                while !running.isTerminated && waited < 3.0 {
                    usleep(200_000)
                    waited += 0.2
                }
                if !running.isTerminated { running.forceTerminate() }
            }

            var total: Int64 = 0
            var aborted = false
            var blocked: [ResidueItem] = []

            do {
                try Trasher.deletePermanently(appItem.path)
                record.items.append(TrashedEntry(
                    original: appItem.path, trashed: "", size: appItem.size, label: appItem.label
                ))
                total += appItem.size
            } catch {
                aborted = true
                record.errors.append("应用本体删除失败：\(error.localizedDescription)")
            }

            if !aborted {
                for item in items {
                    do {
                        try Trasher.deletePermanently(item.path)
                        record.items.append(TrashedEntry(
                            original: item.path, trashed: "", size: item.size, label: item.label
                        ))
                        total += item.size
                    } catch {
                        if isPermissionError(error) {
                            blocked.append(item)
                        } else {
                            record.errors.append("\(item.path)：\(error.localizedDescription)")
                        }
                    }
                }

                if !privileged.isEmpty {
                    do {
                        try Trasher.deleteAsAdmin(privileged.map { $0.path })
                        for item in privileged {
                            record.items.append(TrashedEntry(
                                original: item.path, trashed: "", size: item.size, label: item.label
                            ))
                            total += item.size
                        }
                    } catch {
                        if isPermissionError(error) {
                            blocked.append(contentsOf: privileged)
                        } else {
                            record.errors.append("系统级文件未清理：\(error.localizedDescription)")
                        }
                    }
                }

                Trasher.forgetReceipt(pkgID)
            }

            let rescued = rescueWithFinder(blocked, suffix: "（访达移入废纸篓）", record: &record, total: &total)

            // 本地文件是用户自己的东西，哪怕选了「彻底删除」也只移入废纸篓
            var localTrashed = 0
            for item in localItems {
                guard Safety.checkLocalFile(item.path).ok else {
                    record.errors.append("拒绝操作 \(item.path)")
                    continue
                }
                do {
                    let dest = try Trasher.trash(item.path)
                    record.items.append(TrashedEntry(
                        original: item.path, trashed: dest, size: item.size,
                        label: "本地文件 · " + item.label
                    ))
                    total += item.size
                    localTrashed += 1
                } catch {
                    record.errors.append("\(item.path)：\(error.localizedDescription)")
                }
            }

            record.total_size = total
            try? Trasher.save(record)

            DispatchQueue.main.async {
                self.isBusy = false
                self.status = ""
                if aborted {
                    self.result = ResultPayload(
                        title: "删除中止",
                        message: "应用本体无法删除，已停止操作。\n\(record.errors.first ?? "")",
                        recordID: nil,
                        isError: true
                    )
                } else {
                    var message = "已彻底删除 \(record.items.count) 项，释放 \(ByteFormat.string(total))。"
                    if rescued > 0 {
                        message += "\n其中 \(rescued) 项受系统保护，无法直接删除，已由访达移入废纸篓——清空废纸篓即可彻底清除。"
                    } else {
                        message += "\n此操作不可恢复。"
                    }
                    if localTrashed > 0 {
                        message += "\n\n勾选的 \(localTrashed) 项本地文件只移入了废纸篓，没有彻底删除——那是你自己的文档，留一条退路。需要的话打开废纸篓确认后再清空。"
                    }
                    if !record.errors.isEmpty {
                        message += "\n\(record.errors.count) 项未完成：\n" + record.errors.prefix(3).joined(separator: "\n")
                    }
                    let blockedNow = record.errors.contains {
                        $0.contains("许可") || $0.contains("permission") || $0.contains("Operation not permitted")
                    }
                    if blockedNow {
                        message += "\n\n提示：给本应用授予「完全磁盘访问权限」后重试，可以一次性清理干净。"
                    }
                    self.result = ResultPayload(
                        title: blockedNow ? "部分文件被系统拦截" : "已彻底删除",
                        message: message,
                        recordID: nil,
                        isError: false,
                        needsPermission: blockedNow,
                        showTrashButton: rescued > 0 || localTrashed > 0
                    )
                }
                self.plan = nil
                self.selectedID = nil
                self.refresh()
            }
        }
    }

    // MARK: - 历史与还原

    func loadHistory() {
        DispatchQueue.global(qos: .userInitiated).async {
            let records = Trasher.loadAll()
            DispatchQueue.main.async { self.history = records }
        }
    }

    func restore(_ id: String) {
        isBusy = true
        status = "正在还原…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try Trasher.restore(id)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    var message = "已还原 \(summary.restored) 项到原位置。"
                    if summary.skipped > 0 { message += "\n\(summary.skipped) 项因原位置已存在而跳过。" }
                    if let first = summary.errors.first { message += "\n\(first)" }
                    self.result = ResultPayload(
                        title: "还原完成",
                        message: message,
                        recordID: nil,
                        isError: summary.restored == 0
                    )
                    self.loadHistory()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    self.alert = AlertPayload(title: "还原失败", message: error.localizedDescription, isError: true)
                }
            }
        }
    }

    // MARK: - 安装

    func analyzeInstall(url: URL) {
        isBusy = true
        status = "正在分析 \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let candidate = try Installer.analyze(url)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    self.installCandidate = candidate
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    self.alert = AlertPayload(
                        title: "无法识别这个文件",
                        message: error.localizedDescription,
                        isError: true
                    )
                }
            }
        }
    }

    func confirmInstall(_ candidate: InstallCandidate, destination: String) {
        installCandidate = nil
        isBusy = true
        status = "正在安装 \(candidate.appName)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let target = try Installer.install(candidate, to: destination)
                Installer.release(candidate)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    self.result = ResultPayload(
                        title: "安装完成",
                        message: "\(candidate.appName) 已安装到 \(target)",
                        recordID: nil,
                        isError: false
                    )
                    self.refresh()
                }
            } catch {
                Installer.release(candidate)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    self.alert = AlertPayload(title: "安装失败", message: error.localizedDescription, isError: true)
                }
            }
        }
    }
}
