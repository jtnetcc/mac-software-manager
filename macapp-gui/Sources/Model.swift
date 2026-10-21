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

struct AppInfo: Identifiable, Hashable {
    let path: String
    let name: String
    let bundleID: String
    let version: String
    var size: Int64 = 0

    var id: String { path }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }
}

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
}
