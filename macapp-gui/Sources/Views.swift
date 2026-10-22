import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InstallCandidate: Identifiable {
    var id: String { sourceURL.path }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var showImporter = false
    @State private var showHistory = false
    @State private var dropTargeted = false
    /// 系统软件默认折叠——它们删不掉，也没必要占着列表
    @State private var showSystemApps = ProcessInfo.processInfo.arguments.contains("--expand-system")

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                switch store.mode {
                case .apps:
                    sidebar
                        .frame(width: 268)
                        .background(Color(nsColor: .windowBackgroundColor))
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                case .recommend:
                    RecommendView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                case .orphans:
                    OrphanScanView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.analyzeInstall(url: url)
            }
        }
        .sheet(isPresented: $store.pendingUninstall) { ConfirmUninstallView() }
        .sheet(isPresented: $store.pendingPermanent) { PermanentDeleteView() }
        .sheet(isPresented: $store.pendingOrphanDelete) { OrphanDeleteView() }
        .sheet(item: $store.result) { ResultView(payload: $0) }
        .sheet(item: $store.installCandidate) { InstallSheet(candidate: $0) }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .alert(item: $store.alert) { payload in
            Alert(
                title: Text(payload.title),
                message: Text(payload.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .frame(minWidth: 920, minHeight: 600)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 30, weight: .light))
                            Text("松开即可安装").font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(14)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { store.analyzeInstall(url: url) }
            }
            return true
        }
        .onAppear {
            if store.apps.isEmpty { store.refresh() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { store.mode },
                set: { store.switchMode($0) }
            )) {
                Text("应用").tag(ViewMode.apps)
                Text("推荐").tag(ViewMode.recommend)
                Text("残留扫描").tag(ViewMode.orphans)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 216)

            Text(store.status.isEmpty ? "共 \(store.apps.count) 个应用" : store.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if store.isBusy {
                ProgressView().controlSize(.small)
            }
            Button {
                if store.mode == .orphans { store.scanOrphans() } else { store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help(store.mode == .orphans ? "重新扫描残留文件" : "重新扫描已安装应用")
            .disabled(store.isBusy || store.isScanningOrphans)

            Button {
                showImporter = true
            } label: {
                Image(systemName: "square.and.arrow.down").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("安装 dmg / pkg / zip / app，也可以直接拖进来")

            Button {
                store.loadHistory()
                showHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("查看卸载记录并还原")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !store.userApps.isEmpty {
                        groupHeader("自己装的", count: store.userApps.count, bytes: store.userTotalSize)
                        ForEach(store.userApps) { app in
                            row(for: app)
                        }
                    }
                    if !store.systemApps.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) { showSystemApps.toggle() }
                        } label: {
                            groupHeader(
                                "系统软件", count: store.systemApps.count, bytes: store.systemTotalSize,
                                chevron: showSystemApps ? "chevron.down" : "chevron.right"
                            )
                        }
                        .buttonStyle(.plain)
                        if showSystemApps {
                            ForEach(store.systemApps) { app in
                                row(for: app)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .padding(.bottom, 8)
            }
        }
    }

    private func row(for app: AppInfo) -> some View {
        SidebarRow(
            app: app,
            selected: store.selectedID == app.id,
            share: app.share(of: store.totalFootprint),
            maxShare: maxShare,
            level: store.recommendation(for: app).level
        )
        .onTapGesture { store.select(app.id) }
    }

    /// 占比条按最大项归一化，否则小应用那条线根本看不见
    private var maxShare: Double {
        store.apps.map { $0.share(of: store.totalFootprint) }.max() ?? 0
    }

    private func groupHeader(
        _ title: String, count: Int, bytes: Int64, chevron: String? = nil
    ) -> some View {
        HStack(spacing: 5) {
            if let chevron {
                Image(systemName: chevron)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 8)
            }
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(ByteFormat.string(bytes))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detail: some View {
        if let plan = store.plan {
            PlanView(plan: plan)
        } else if store.isBusy {
            CenteredHint(icon: "magnifyingglass", title: store.status, subtitle: "正在读取文件占用，稍等片刻")
        } else if store.selectedID != nil {
            CenteredHint(icon: "magnifyingglass", title: "正在准备…", subtitle: "")
        } else {
            EmptyStateView { showImporter = true }
        }
    }

}

// MARK: - 权限提示条

/// 授权相关的提示。三个容易踩的坑都在这里说清楚：
/// 1. 应用要拖进 /Applications，从 dmg 里直接跑会被系统「传送」到随机路径，授权留不住
/// 2. 加进列表后必须重启进程，TCC 的判定按进程缓存
/// 3. 列表里那条记录必须指向当前这个应用
struct PermissionBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: Safety.isTranslocated ? "exclamationmark.triangle" : "lock.shield")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Button("显示位置") { Safety.revealAppInFinder() }
                    .controlSize(.small)
                    .help("在访达中选中本应用，可以直接拖进「完全磁盘访问权限」列表")
                Button("去授权") { Safety.openFullDiskAccessSettings() }
                    .controlSize(.small)
                Button("重新检测") { store.recheckPermission() }
                    .controlSize(.small)
                Button("重启应用") { store.relaunchApp() }
                    .controlSize(.small)
                    .help("授权后必须重启进程才读得到新权限")
            }
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if Safety.isTranslocated {
                Text("当前运行路径：\(Safety.appBundlePath)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var title: String {
        if Safety.isTranslocated { return "请先把应用拖进「应用程序」文件夹" }
        switch store.permission {
        case .denied: return "没有「完全磁盘访问权限」"
        case .unknown: return "无法确认磁盘访问权限"
        case .granted: return "磁盘访问权限正常"
        }
    }

    private var detail: String {
        if Safety.isTranslocated {
            return "你正在从 dmg 或压缩包里直接运行，系统把应用挂在一个每次都不一样的只读路径下，授权永远留不住。拖进「应用程序」文件夹后再打开。"
        }
        switch store.permission {
        case .denied:
            return "其他应用的沙盒容器会被系统拦截。加进「完全磁盘访问权限」并打开开关后，点「重启应用」才生效。"
        case .unknown:
            return "本机找不到可用于判断的受保护文件。不影响使用，删除被拦截时会自动改由访达处理。"
        case .granted:
            return ""
        }
    }
}

// MARK: - 侧边栏行

struct SidebarRow: View {
    let app: AppInfo
    let selected: Bool
    /// 占全部应用总占用的比例
    let share: Double
    /// 最大项占比，用于把条形长度归一化
    let maxShare: Double
    let level: RecommendLevel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(app.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if app.isSystem {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                        .help("系统自带，删不掉")
                }
                Spacer(minLength: 0)
                if !level.shortLabel.isEmpty {
                    Text(level.shortLabel)
                        .font(.system(size: 8.5, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Self.tint(level).opacity(0.16), in: Capsule())
                        .foregroundStyle(Self.tint(level))
                }
            }
            HStack(spacing: 4) {
                Text(ByteFormat.string(app.footprint))
                    .font(.system(size: 10))
                Text("·")
                    .font(.system(size: 10))
                Text(RecommendationEngine.usageText(app))
                    .font(.system(size: 10))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(ByteFormat.percent(share))
                    .font(.system(size: 9.5, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
            ShareBar(value: maxShare > 0 ? share / maxShare : 0, tint: Self.tint(level))
                .padding(.leading, 30)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    static func tint(_ level: RecommendLevel) -> Color {
        switch level {
        case .strong: return .orange
        case .consider: return .yellow
        case .keep: return .accentColor
        }
    }
}

// MARK: - 占比条

/// 细横条，用来比出「谁占得多」。值会被归一化到最大项，所以是相对长度不是绝对百分比。
struct ShareBar: View {
    let value: Double
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(tint.opacity(0.75))
                    .frame(width: max(1.5, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 2.5)
    }
}

// MARK: - 体积构成小标签

struct SizeChip: View {
    let label: String
    let bytes: Int64
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(ByteFormat.string(bytes))
                .foregroundStyle(tint)
        }
        .font(.system(size: 9.5))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(tint.opacity(0.10), in: Capsule())
    }
}

// MARK: - 推荐卸载

struct RecommendView: View {
    @EnvironmentObject var store: Store

    private var items: [(app: AppInfo, rec: Recommendation)] { store.recommendedApps }

    private var maxShare: Double {
        items.map { $0.app.share(of: store.totalFootprint) }.max() ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("推荐卸载")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(items.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isBusy && store.apps.isEmpty {
                    ProgressView().controlSize(.small)
                }
                if !items.isEmpty {
                    Text("可释放 \(ByteFormat.string(store.recommendedBytes))")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.orange)
                    if store.diskCapacity > 0 {
                        Text("占磁盘 \(ByteFormat.percent(Double(store.recommendedBytes) / Double(store.diskCapacity)))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else if !store.apps.isEmpty {
                    Text("共 \(store.apps.count) 个应用 · \(ByteFormat.string(store.totalFootprint))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Text("按「多久没用」和「缓存大小」综合打分。推荐只是建议——不会自动勾选，也不会替你删任何东西。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if store.recommendedCacheBytes > 0 {
                Text("其中缓存 \(ByteFormat.string(store.recommendedCacheBytes))，这部分清掉不影响应用本身。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if store.apps.isEmpty {
            CenteredHint(icon: "sparkle.magnifyingglass", title: "正在分析…",
                         subtitle: "读取使用记录和缓存占用，大约几秒")
        } else if items.isEmpty {
            // 没有推荐不代表没信息——至少告诉用户空间都去哪了
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.seal")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("没有值得卸载的应用")
                                .font(.system(size: 12.5, weight: .medium))
                            Text("\(store.apps.count) 个应用里，最近都在用、缓存也不大。下面是占用最多的几个，供参考。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))

                    Text("占用排行")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)

                    ForEach(store.apps.sorted { $0.footprint > $1.footprint }.prefix(10)) { app in
                        TopFootprintRow(
                            app: app,
                            share: app.share(of: store.totalFootprint),
                            maxShare: maxShareOfAll
                        ) {
                            store.inspectFromRecommend(app)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(items, id: \.app.id) { item in
                        RecommendRow(
                            app: item.app,
                            rec: item.rec,
                            share: item.app.share(of: store.totalFootprint),
                            maxShare: maxShare
                        ) {
                            store.inspectFromRecommend(item.app)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var maxShareOfAll: Double {
        store.apps.map { $0.share(of: store.totalFootprint) }.max() ?? 0
    }
}

/// 没有推荐时的占用排行行，不显示推荐等级
struct TopFootprintRow: View {
    let app: AppInfo
    let share: Double
    let maxShare: Double
    let onInspect: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 22, height: 22)
            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
            if app.isSystem {
                Text("系统")
                    .font(.system(size: 8.5))
                    .padding(.horizontal, 3)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            ShareBar(value: maxShare > 0 ? share / maxShare : 0, tint: .accentColor)
                .frame(width: 150)
            Spacer(minLength: 6)
            Text(ByteFormat.string(app.footprint))
                .font(.system(size: 11, design: .monospaced))
            Text(ByteFormat.percent(share))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
            Button("查看") { onInspect() }
                .controlSize(.small)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct RecommendRow: View {
    let app: AppInfo
    let rec: Recommendation
    let share: Double
    let maxShare: Double
    let onInspect: () -> Void

    private var tint: Color { SidebarRow.tint(rec.level) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(rec.level.label)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.16), in: Capsule())
                        .foregroundStyle(tint)
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(app.footprint))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                HStack(spacing: 5) {
                    Text(RecommendationEngine.usageText(app))
                        .foregroundStyle(rec.reasons.isEmpty ? .secondary : .secondary)
                    Text(app.usageSource.label)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text("占应用总占用 \(ByteFormat.percent(share))")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 10.5))
                ShareBar(value: maxShare > 0 ? share / maxShare : 0, tint: tint)
                    .frame(maxWidth: 320)
                HStack(spacing: 6) {
                    if app.cacheSize > 0 {
                        SizeChip(label: "缓存", bytes: app.cacheSize, tint: .blue)
                    }
                    if app.dataSize > 0 {
                        SizeChip(label: "数据", bytes: app.dataSize, tint: .purple)
                    }
                    Text(rec.reasons.joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Button("查看") { onInspect() }
                .controlSize(.small)
                .help("打开卸载清单，自己确认要删哪些")
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(tint.opacity(rec.level == .strong ? 0.28 : 0.0), lineWidth: 1)
        )
    }
}

// MARK: - 详情

struct PlanView: View {
    let plan: ScanPlan
    @EnvironmentObject var store: Store

    private var allSelected: Bool {
        !plan.items.isEmpty && plan.items.allSatisfy { $0.selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if Safety.isTranslocated || store.permission == .denied {
                        PermissionBanner()
                    }
                    appRow
                    sectionHeader
                    ForEach(plan.items) { item in
                        itemRow(item)
                        Divider().padding(.leading, 44)
                    }
                    if plan.items.isEmpty {
                        Text("没有找到残留文件，只会移除应用本体。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    localFileSection
                    notes
                }
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: plan.app.icon)
                .resizable()
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.app.name)
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 8) {
                    if !plan.app.version.isEmpty {
                        Text("v\(plan.app.version)")
                    }
                    Text(plan.app.bundleID)
                        .font(.system(size: 11, design: .monospaced))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                Text(plan.app.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                footprintLine
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteFormat.string(plan.totalSize))
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                Text(plan.app.isSystem ? "总占用" : "可清理")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if store.totalFootprint > 0 {
                    Text("占应用总占用 \(ByteFormat.percent(plan.app.share(of: store.totalFootprint)))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 体积构成 + 最后使用时间。四个新字段在这里一次性交代清楚，
    /// 用户不用切到别的页面就能判断「这东西到底占在哪、还用不用」。
    private var footprintLine: some View {
        HStack(spacing: 6) {
            if plan.app.isSystem {
                Text("系统自带")
                    .font(.system(size: 9.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(.secondary)
            }
            if plan.app.size > 0 {
                SizeChip(label: "本体", bytes: plan.app.size, tint: .accentColor)
            }
            if plan.app.dataSize > 0 {
                SizeChip(label: "数据", bytes: plan.app.dataSize, tint: .purple)
            }
            if plan.app.cacheSize > 0 {
                SizeChip(label: "缓存", bytes: plan.app.cacheSize, tint: .blue)
            }
            Text("·")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(RecommendationEngine.usageText(plan.app))
                .font(.system(size: 10))
                .foregroundStyle(plan.app.usageSource.trustable ? .secondary : .tertiary)
            Text(plan.app.usageSource.label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    private var appRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("应用程序").font(.system(size: 12, weight: .medium))
                    Text("必删").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
                Text(plan.appItem.shortPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(plan.appItem.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            Text("残留文件 \(plan.items.count) 项")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button(allSelected ? "全不选" : "全选") {
                store.toggleAll(!allSelected)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
            .disabled(plan.items.isEmpty)
            Toggle("低置信度", isOn: Binding(
                get: { store.includeLow },
                set: { store.setIncludeLow($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    // MARK: 本地文件

    private var localAllSelected: Bool {
        !plan.localFiles.isEmpty && plan.localFiles.allSatisfy { $0.selected }
    }

    @ViewBuilder
    private var localFileSection: some View {
        if !plan.localFiles.isEmpty {
            Divider().padding(.top, 10)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("本地文件 \(plan.localFiles.count) 项 · \(ByteFormat.string(plan.localTotalSize))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("应用在你自己的文件夹里留下的东西，默认不删，你自己判断要不要一起清")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(localAllSelected ? "全不选" : "全选") {
                    store.toggleAllLocal(!localAllSelected)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 5)

            ForEach(plan.localFiles) { item in
                localRow(item)
                Divider().padding(.leading, 44)
            }
        }
    }

    private func localRow(_ item: ResidueItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { store.plan?.localFiles.first(where: { $0.path == item.path })?.selected ?? item.selected },
                set: { store.toggleLocal(item.path, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text((item.path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Text(item.shortPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(item.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                store.revealLocal(item.path)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在访达中显示")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private func itemRow(_ item: ResidueItem) -> some View {        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: {
                    store.plan?.items.first(where: { $0.id == item.id })?.selected ?? item.selected
                },
                set: { value in
                    if let index = store.plan?.items.firstIndex(where: { $0.id == item.id }) {
                        store.plan?.items[index].selected = value
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.label).font(.system(size: 12, weight: .medium))
                    ConfidenceBadge(confidence: item.confidence)
                }
                Text(item.shortPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(item.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var notes: some View {
        if !plan.privileged.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("需要管理员权限，本次不处理（\(plan.privileged.count) 项）")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                ForEach(plan.privileged) { item in
                    Text(item.shortPath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("如需彻底清理，可在终端执行：")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                ForEach(plan.privileged.prefix(4)) { item in
                    Text("sudo rm -rf '\(item.path)'")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 18)
            .padding(.top, 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("已选 \(plan.selectedItems.count + 1 + plan.selectedLocalFiles.count) 项 · \(ByteFormat.string(plan.selectedSize))")
                    .font(.system(size: 12))
                Text(footerHint)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plan.app.path)])
            }
            Button("重新扫描") { store.rescan() }
            if plan.app.isSystem {
                Label("系统自带，不可卸载", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .help("系统软件受 SIP 保护，删不掉也不该删。这里只展示它占了多少空间。")
            } else {
                ActionButton(
                    title: "移入废纸篓",
                    systemImage: "trash",
                    tint: .primary,
                    background: Color.primary.opacity(0.06)
                ) {
                    store.pendingUninstall = true
                }
                .help("可恢复，随时能从历史记录还原")
                .disabled(store.isBusy)
                .opacity(store.isBusy ? 0.45 : 1)

                ActionButton(
                    title: "彻底删除",
                    systemImage: "trash.slash",
                    tint: .red,
                    background: Color.red.opacity(0.12)
                ) {
                    store.pendingPermanent = true
                }
                .help("直接删除，不进入废纸篓，无法恢复")
                .disabled(store.isBusy)
                .opacity(store.isBusy ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footerHint: String {
        if plan.app.isSystem { return "系统软件受 SIP 保护，删不掉也不该删" }
        return plan.selectedLocalFiles.isEmpty
            ? "移入废纸篓可还原；彻底删除不可恢复"
            : "本地文件只会进废纸篓，不会被彻底删除"
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    var background: Color = Color.primary.opacity(0.06)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 0.5)
            )
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Text(confidence.label)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .secondary
        }
    }
}

// MARK: - 残留扫描

struct OrphanScanView: View {
    @EnvironmentObject var store: Store

    private var allSelected: Bool {
        !store.orphans.isEmpty && store.orphans.allSatisfy { $0.selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isScanningOrphans {
                CenteredHint(
                    icon: "magnifyingglass",
                    title: "正在扫描残留文件…",
                    subtitle: "检查容器、应用数据、缓存、偏好设置等 10 个位置"
                )
            } else if store.orphans.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 3) {
                Text("残留扫描")
                    .font(.system(size: 17, weight: .semibold))
                Text("找出「应用已经删掉、数据还留着」的目录，包括以前卸载没清干净的部分。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Text("默认只勾选与任何已装应用都对不上的标识；靠名称模糊匹配出来的标为中置信度，需要你自己确认。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ByteFormat.string(store.orphanTotalSize))
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                Text("可回收")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(store.orphanScanned ? "没有发现残留" : "还没有扫描")
                .font(.system(size: 13, weight: .medium))
            Text(store.orphanScanned
                 ? "所有数据目录都能对应到已安装的应用。\n可以勾选下面的「包含中置信度」再找一遍。"
                 : "点右上角的刷新按钮开始扫描。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if Safety.isTranslocated || store.permission == .denied {
                    PermissionBanner()
                }
                ForEach(store.orphanGroups, id: \.category) { group in
                    groupHeader(group.category, items: group.items)
                    ForEach(group.items) { item in
                        row(item)
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private func groupHeader(_ category: String, items: [OrphanItem]) -> some View {
        let groupSize = items.reduce(Int64(0)) { $0 + $1.size }
        let groupAllSelected = items.allSatisfy { $0.selected }
        return HStack(spacing: 8) {
            Text(category)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text("\(items.count) 项 · \(ByteFormat.string(groupSize))")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(groupAllSelected ? "取消本组" : "选中本组") {
                for item in items { store.toggleOrphan(item.path, !groupAllSelected) }
            }
            .buttonStyle(.link)
            .font(.system(size: 10.5))
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 5)
    }

    private func row(_ item: OrphanItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { store.orphans.first(where: { $0.path == item.path })?.selected ?? item.selected },
                set: { store.toggleOrphan(item.path, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    OrphanConfidenceBadge(confidence: item.confidence)
                }
                Text(item.shortPath)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(ByteFormat.string(item.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Button {
                store.revealOrphan(item.path)
            } label: {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在访达中显示")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("已选 \(store.selectedOrphans.count) 项 · \(ByteFormat.string(store.selectedOrphanSize))")
                    .font(.system(size: 12))
                Text("下一步可以选移入废纸篓或彻底删除")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !store.orphans.isEmpty {
                Button(allSelected ? "全不选" : "全选") {
                    store.toggleAllOrphans(!allSelected)
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
            Toggle("包含中置信度", isOn: Binding(
                get: { store.includeMediumOrphans },
                set: { store.setIncludeMediumOrphans($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            ActionButton(
                title: "清理…",
                systemImage: "trash",
                tint: .primary,
                background: Color.primary.opacity(0.06)
            ) {
                store.pendingOrphanDelete = true
            }
            .help("可以选择移入废纸篓（可还原）或彻底删除")
            .disabled(store.isBusy || store.selectedOrphans.isEmpty)
            .opacity((store.isBusy || store.selectedOrphans.isEmpty) ? 0.45 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

struct OrphanConfidenceBadge: View {
    let confidence: OrphanConfidence

    var body: some View {
        Text(confidence.label)
            .font(.system(size: 9.5, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        confidence == .high ? .green : .orange
    }
}

// MARK: - 弹窗

struct ConfirmUninstallView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let plan = store.plan
        let items = (plan?.allItems ?? []) + (plan?.selectedLocalFiles ?? [])
        let localCount = plan?.selectedLocalFiles.count ?? 0

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(.orange)
                Text("确认卸载 \(plan?.app.name ?? "")？")
                    .font(.system(size: 15, weight: .semibold))
            }

            Text("以下 \(items.count) 项将移入废纸篓，共 \(ByteFormat.string(plan?.selectedSize ?? 0))。卸载后会退出该应用，随时可从「历史记录」一键还原。\(localCount > 0 ? "\n其中 \(localCount) 项是你勾选的本地文件，一样在废纸篓里。" : "")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 3))
                                .foregroundStyle(.tertiary)
                            Text(item.shortPath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 170)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            HStack {
                Spacer()
                Button("取消") { store.pendingUninstall = false }
                    .keyboardShortcut(.cancelAction)
                Button("卸载") { store.performUninstall() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct PermanentDeleteView: View {
    @EnvironmentObject var store: Store
    @State private var acknowledged = false
    @State private var includePrivileged = true

    var body: some View {
        let plan = store.plan
        let items = (plan?.allItems ?? []) + (plan?.selectedLocalFiles ?? [])
        let privileged = plan?.privileged ?? []
        let localCount = plan?.selectedLocalFiles.count ?? 0

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("彻底删除 \(plan?.app.name ?? "")？")
                        .font(.system(size: 15, weight: .semibold))
                    Text("不进入废纸篓，删除后无法恢复")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }

            Text("将永久删除 \(items.count) 项，释放 \(ByteFormat.string(plan?.selectedSize ?? 0))。这个操作没有撤销，历史记录里也不会保留可还原的副本。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if localCount > 0 {
                Text("其中 \(localCount) 项是你自己的本地文件，会移入废纸篓而不是彻底删除——那是你的文档，留一条退路。")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 3))
                                .foregroundStyle(.tertiary)
                            Text(item.shortPath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: 150)
            .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))

            if !privileged.isEmpty {
                Toggle(isOn: $includePrivileged) {
                    Text("同时清理 \(privileged.count) 项系统级文件（需要输入管理员密码）")
                        .font(.system(size: 11.5))
                }
                .toggleStyle(.checkbox)
            }

            Toggle(isOn: $acknowledged) {
                Text("我确认这些文件不再需要，删除后不要求恢复")
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button("取消") { store.pendingPermanent = false }
                    .keyboardShortcut(.cancelAction)
                Button("彻底删除") {
                    store.performPermanentDelete(includePrivileged: includePrivileged)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!acknowledged)
            }
        }
        .padding(22)
        .frame(width: 480)
    }
}

struct OrphanDeleteView: View {
    @EnvironmentObject var store: Store
    @State private var acknowledged = false
    @State private var permanentConfirmed = false

    private var bigItems: [OrphanItem] {
        store.selectedOrphans.filter { $0.size >= 500 * 1024 * 1024 }
    }

    var body: some View {
        let items = store.selectedOrphans
        let total = store.selectedOrphanSize

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: bigItems.isEmpty ? "trash" : "exclamationmark.triangle.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(bigItems.isEmpty ? Color.accentColor : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理 \(items.count) 项残留？")
                        .font(.system(size: 15, weight: .semibold))
                    Text("共 \(ByteFormat.string(total))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Text("这些目录已经不属于任何已安装的应用，但里面可能还有旧登录状态、聊天记录或本地文件。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !bigItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("注意：其中有 \(bigItems.count) 项体积很大")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.orange)
                    ForEach(bigItems.prefix(3)) { item in
                        Text("\(ByteFormat.string(item.size))  \(item.shortPath)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("这么大的目录通常说明对应的应用还在用。建议先移入废纸篓，确认没问题再清空。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 3))
                                .foregroundStyle(.tertiary)
                            Text(item.shortPath)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(ByteFormat.string(item.size))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(height: min(CGFloat(items.count) * 21 + 22, 150))
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            if !store.hasFullDiskAccess {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("没有完全磁盘访问权限，沙盒容器里的项会被系统拦截，届时会改由访达移入废纸篓。")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $acknowledged) {
                Text("我确认这些目录确实不再需要")
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $permanentConfirmed) {
                Text("我确认要彻底删除，不经过废纸篓，删完无法恢复")
                    .font(.system(size: 11.5))
            }
            .toggleStyle(.checkbox)
            .disabled(!acknowledged)

            HStack {
                Spacer()
                Button("取消") { store.pendingOrphanDelete = false }
                    .keyboardShortcut(.cancelAction)
                Button("彻底删除") {
                    store.performOrphanDelete(toTrash: false)
                }
                .tint(.red)
                .disabled(!acknowledged || !permanentConfirmed || items.isEmpty)
                Button("移入废纸篓") {
                    store.performOrphanDelete(toTrash: true)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!acknowledged || items.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

struct ResultView: View {
    @EnvironmentObject var store: Store
    let payload: ResultPayload
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: payload.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(payload.isError ? Color.red : Color.green)
                Text(payload.title).font(.system(size: 15, weight: .semibold))
            }
            Text(payload.message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if payload.showTrashButton {
                    Button("打开废纸篓") { FinderBridge.openTrash() }
                }
                if payload.needsPermission {
                    Button("打开权限设置") { Safety.openFullDiskAccessSettings() }
                }
                if let recordID = payload.recordID {
                    Button("还原这次卸载") {
                        dismiss()
                        store.restore(recordID)
                    }
                }
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct InstallSheet: View {
    @EnvironmentObject var store: Store
    let candidate: InstallCandidate
    @State private var destination = Installer.destinations[0]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(Color.accentColor)
                Text("安装 \(candidate.appName)").font(.system(size: 15, weight: .semibold))
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("来源").foregroundStyle(.secondary)
                    Text(candidate.sourceURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                GridRow {
                    Text("格式").foregroundStyle(.secondary)
                    Text(candidate.kind.rawValue)
                }
                if !candidate.version.isEmpty {
                    GridRow {
                        Text("版本").foregroundStyle(.secondary)
                        Text(candidate.version)
                    }
                }
                if !candidate.bundleID.isEmpty {
                    GridRow {
                        Text("标识").foregroundStyle(.secondary)
                        Text(candidate.bundleID).font(.system(size: 11, design: .monospaced))
                    }
                }
                GridRow {
                    Text("大小").foregroundStyle(.secondary)
                    Text(ByteFormat.string(candidate.size))
                }
                GridRow {
                    Text("安装到").foregroundStyle(.secondary)
                    Picker("", selection: $destination) {
                        ForEach(Installer.destinations, id: \.self) { path in
                            Text(path).tag(path)
                        }
                    }
                    .labelsHidden()
                }
            }
            .font(.system(size: 12))

            Text("如果目标位置已有同名应用，旧版本会先移入废纸篓，可随时还原。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            HStack {
                Spacer()
                Button("取消") {
                    Installer.release(candidate)
                    store.installCandidate = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("安装") {
                    store.confirmInstall(candidate, destination: destination)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}

struct HistoryView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("卸载记录").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
            }

            if store.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有卸载记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.history) { record in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.app).font(.system(size: 12, weight: .medium))
                                    Text("\(record.created) · \(record.items.count) 项 · \(ByteFormat.string(record.total_size ?? 0))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                    if record.isPermanent {
                                        Text("已彻底删除，不可还原")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.red)
                                    } else if record.restored_at != nil {
                                        Text("已还原")
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                if record.isPermanent {
                                    Text("—")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Button("还原") { store.restore(record.id) }
                                        .disabled(record.restored_at != nil)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .frame(height: 320)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    var onInstall: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("从左边选一个应用")
                .font(.system(size: 13, weight: .medium))
            Text("会列出它散落在系统各处的全部文件，确认后再动手。\n也可以把 dmg / pkg / zip 直接拖进来安装。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("选择安装包…", action: onInstall)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CenteredHint: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text(title.isEmpty ? "处理中…" : title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
