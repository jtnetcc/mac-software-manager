import AppKit
import Foundation

enum Confidence: String, Codable, Comparable {
    case high, medium, low

    var label: String {
        switch self {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    var rank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }

    static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}

/// 最后使用时间是从哪来的。
///
/// macOS 没有「应用上次启动时间」这种公开 API，只能拼凑。三路来源的覆盖率和精度差很多，
/// 所以必须把来源一起带出来——否则界面上写着「3 个月没用」，用户会以为这是系统记录。
enum UsageSource: String, Codable {
    /// Spotlight 的 `kMDItemLastUsedDate`，精确到秒，但只覆盖约 8% 的应用
    case spotlight
    /// 应用数据目录的最新修改时间，精确到天，覆盖约一半
    case activity
    /// 只有应用本体的修改时间，只能说明安装/更新时间，不能说明用过
    case install
    case unknown

    var label: String {
        switch self {
        case .spotlight: return "系统记录"
        case .activity: return "数据活跃"
        case .install: return "仅安装时间"
        case .unknown: return "无记录"
        }
    }

    /// 这个时间能不能用来判断「多久没用」
    var trustable: Bool { self == .spotlight || self == .activity }
}

struct AppInfo: Identifiable, Hashable {
    let path: String
    let name: String
    let bundleID: String
    let version: String
    /// 应用本体（.app 包）
    var size: Int64 = 0
    /// 应用数据：沙盒容器、Application Support、偏好设置、保存状态。不含独立缓存目录。
    var dataSize: Int64 = 0
    /// 可安全清理的缓存目录
    var cacheSize: Int64 = 0
    var lastUsed: Date?
    var usageSource: UsageSource = .unknown
    /// 系统自带 / Apple 签名，不建议卸载
    var isSystem: Bool = false
    /// Apple 签名（含第三方应用里 Apple 签的部分组件）
    var isAppleSigned: Bool = false

    var id: String { path }

    /// 应用在磁盘上的全部占用
    var footprint: Int64 { size + dataSize + cacheSize }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    /// 占全部应用总占用的比例
    func share(of total: Int64) -> Double {
        guard total > 0, footprint > 0 else { return 0 }
        return Double(footprint) / Double(total)
    }

    /// 占磁盘总容量的比例
    func shareOfDisk(_ capacity: Int64) -> Double {
        guard capacity > 0, footprint > 0 else { return 0 }
        return Double(footprint) / Double(capacity)
    }
}

// MARK: - 推荐卸载

enum RecommendLevel: Int, Comparable {
    case keep = 0
    case consider = 1
    case strong = 2

    var label: String {
        switch self {
        case .keep: return "不建议"
        case .consider: return "可以考虑"
        case .strong: return "推荐卸载"
        }
    }

    var shortLabel: String {
        switch self {
        case .keep: return ""
        case .consider: return "可考虑"
        case .strong: return "推荐"
        }
    }

    static func < (lhs: RecommendLevel, rhs: RecommendLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct Recommendation {
    let level: RecommendLevel
    let score: Int
    let reasons: [String]

    var isRecommendation: Bool { level != .keep }
}

/// 推荐规则。故意做成纯函数：不碰磁盘、不看时间，方便自检里逐个用例验证。
///
/// 设计原则和残留扫描一致——**宁可漏报，不可错杀**。这里给出的是「建议」，
/// 最终勾选永远由用户自己做，任何推荐都不会自动选中。
enum RecommendationEngine {
    struct Context {
        /// 所有应用的占用总和，用于算占比
        var totalFootprint: Int64 = 0
        var diskCapacity: Int64 = 0
        var diskFree: Int64 = 0
    }

    /// 低于这个分数不推荐
    static let considerThreshold = 25
    /// 达到这个分数算强烈推荐
    static let strongThreshold = 50

    static func evaluate(_ app: AppInfo, context: Context = Context(), now: Date = Date()) -> Recommendation {
        // 系统软件永远不推荐
        if app.isSystem {
            return Recommendation(level: .keep, score: 0, reasons: ["系统自带，不建议卸载"])
        }

        var score = 0
        var reasons: [String] = []
        let days = daysSince(app.lastUsed, now: now)
        let trusted = app.usageSource.trustable

        // 1. 多久没用
        if let days, trusted {
            switch days {
            case 365...:
                score += 45
                reasons.append("超过一年没打开")
            case 180..<365:
                score += 32
                reasons.append("半年多没打开")
            case 90..<180:
                score += 20
                reasons.append("三个月没打开")
            case 60..<90:
                score += 10
                reasons.append("两个月没打开")
            default:
                break
            }
        }

        // 2. 缓存过大
        switch app.cacheSize {
        case 5_000_000_000...:
            score += 25
            reasons.append("缓存 \(ByteFormat.string(app.cacheSize))")
        case 1_000_000_000...:
            score += 15
            reasons.append("缓存 \(ByteFormat.string(app.cacheSize))")
        case 500_000_000...:
            score += 7
            reasons.append("缓存 \(ByteFormat.string(app.cacheSize))")
        default:
            break
        }

        // 3. 本体体积
        switch app.size {
        case 2_000_000_000...:
            score += 15
            reasons.append("本体 \(ByteFormat.string(app.size))")
        case 1_000_000_000...:
            score += 8
            reasons.append("本体 \(ByteFormat.string(app.size))")
        default:
            break
        }

        // 4. 数据比本体大很多（典型：试用过一次就没再打开的客户端）
        if app.size > 0, app.dataSize >= 1_000_000_000, app.dataSize >= app.size * 3 {
            score += 10
            reasons.append("数据 \(ByteFormat.string(app.dataSize))，是本体 \(app.dataSize / app.size) 倍")
        }

        // 最近 30 天用过：除非缓存特别大，否则不该推荐
        if let days, trusted, days < 30 {
            if app.cacheSize < 5_000_000_000 {
                return Recommendation(level: .keep, score: 0, reasons: ["最近 \(max(days, 0)) 天用过"])
            }
            reasons.append("最近 \(max(days, 0)) 天用过，但缓存很大")
        }

        let level: RecommendLevel
        if score >= strongThreshold {
            level = .strong
        } else if score >= considerThreshold {
            level = .consider
        } else {
            level = .keep
        }
        if level == .keep && reasons.isEmpty {
            reasons.append("近期在用，占用也不大")
        }
        return Recommendation(level: level, score: score, reasons: reasons)
    }

    static func daysSince(_ date: Date?, now: Date) -> Int? {
        guard let date else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: now).day
    }

    /// 把「多久没用」翻译成一句人话
    static func usageText(_ app: AppInfo, now: Date = Date()) -> String {
        guard let date = app.lastUsed else { return "从未记录" }
        guard let days = daysSince(date, now: now) else { return "—" }
        switch days {
        case ..<0: return "刚刚"
        case 0: return "今天用过"
        case 1: return "昨天用过"
        case 2...30: return "\(days) 天前用过"
        case 31...60: return "1 个月前用过"
        case 61...180: return "\(days / 30) 个月前用过"
        case 181...365: return "半年前用过"
        default: return "\(days / 365) 年前用过"
        }
    }
}

// MARK: - 清单与记录

struct ResidueItem: Identifiable, Hashable {
    let path: String
    let label: String
    let confidence: Confidence
    let size: Int64
    let privileged: Bool
    /// 用户自己创建的文件（文档/下载），只允许移入废纸篓，默认不勾选
    var local: Bool = false
    var selected: Bool = true

    var id: String { path }

    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

struct ScanPlan {
    var app: AppInfo
    var appItem: ResidueItem
    var items: [ResidueItem]
    var privileged: [ResidueItem]
    var notes: [String]
    /// 应用在用户文件夹里留下的东西，需要用户自己决定要不要删
    var localFiles: [ResidueItem] = []

    var allItems: [ResidueItem] { [appItem] + items }
    var selectedItems: [ResidueItem] { items.filter { $0.selected } }
    var selectedLocalFiles: [ResidueItem] { localFiles.filter { $0.selected } }
    var totalSize: Int64 { allItems.reduce(0) { $0 + $1.size } }
    var localTotalSize: Int64 { localFiles.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 {
        ([appItem] + selectedItems + selectedLocalFiles).reduce(0) { $0 + $1.size }
    }
}

struct TrashedEntry: Codable {
    let original: String
    let trashed: String
    let size: Int64
    let label: String
}

struct UninstallRecord: Codable, Identifiable {
    var id: String
    var created: String
    var app: String
    var bundle_id: String?
    var path: String?
    var items: [TrashedEntry]
    var errors: [String]
    var total_size: Int64?
    var restored_at: String?
    var permanent: Bool?

    var isPermanent: Bool { permanent == true }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024 && index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return String(format: "%.0f B", value) }
        return String(format: "%.1f %@", value, units[index])
    }

    /// 占比：小于 1% 显示一位小数，避免全是「0%」
    static func percent(_ ratio: Double) -> String {
        guard ratio > 0 else { return "0%" }
        let value = ratio * 100
        if value < 0.1 { return "<0.1%" }
        if value < 1 { return String(format: "%.2f%%", value) }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }
}
