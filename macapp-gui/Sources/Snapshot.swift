import AppKit
import SwiftUI

/// 隐藏模式：`MacApp --snapshot <输出路径> [应用名]`
/// 把界面渲染成 PNG，方便在没有屏幕录制权限时自查排版。
enum Snapshot {
    static func run(path: String, appName: String?, mode: String? = nil) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let store = Store()
        let root = ContentView().environmentObject(store)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac软件管家"
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(NSRect(x: 80, y: 80, width: 1080, height: 720), display: true)
        window.makeKeyAndOrderFront(nil)

        store.refresh()
        waitUntil { !store.isBusy && !store.apps.isEmpty }

        if mode == "orphan" || mode == "orphan-all" {
            store.switchMode(.orphans)
            if mode == "orphan-all" { store.setIncludeMediumOrphans(true) }
            waitUntil { store.orphanScanned && !store.isScanningOrphans }
        } else if let appName,
                  let match = store.apps.first(where: { $0.name.contains(appName) }) {
            store.select(match.id)
            waitUntil { store.plan != nil }
        } else if let first = store.apps.first {
            store.select(first.id)
            waitUntil { store.plan != nil }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        guard let content = window.contentView else {
            print("snapshot failed: no content view")
            return
        }

        print("fullSize=\(window.styleMask.contains(.fullSizeContentView)) transparent=\(window.titlebarAppearsTransparent)")
        print("frame=\(window.frame) contentLayout=\(window.contentLayoutRect) safeArea=\(content.safeAreaInsets)")

        // 优先用窗口级截屏，能正确包含侧边栏的毛玻璃层；失败再退回视图缓存绘制
        if let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming]
        ) {
            let rep = NSBitmapImageRep(cgImage: cgImage)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                print("snapshot(window): \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
                RunLoop.main.run(until: Date().addingTimeInterval(4))
                if let late = CGWindowListCreateImage(
                    .null,
                    .optionIncludingWindow,
                    CGWindowID(window.windowNumber),
                    [.boundsIgnoreFraming]
                ) {
                    let lateRep = NSBitmapImageRep(cgImage: late)
                    if let lateData = lateRep.representation(using: .png, properties: [:]) {
                        let latePath = path.replacingOccurrences(of: ".png", with: "-late.png")
                        try? lateData.write(to: URL(fileURLWithPath: latePath))
                        print("snapshot(late): \(latePath)")
                    }
                }
                return
            }
        }

        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            print("snapshot failed: no bitmap rep")
            return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("snapshot failed: no png data")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            print("snapshot(view): \(path)")
        } catch {
            print("snapshot failed: \(error.localizedDescription)")
        }
    }

    /// 用 SwiftUI 自带渲染器离屏渲染详情页，绕过窗口合成，用于判断问题出在代码还是截图方式。
    @MainActor
    static func renderDetail(path: String, appName: String?) {
        let store = Store()
        let apps = Scanner.discoverApps()
        guard let app = apps.first(where: { appName == nil || $0.name.contains(appName!) }) ?? apps.first else {
            print("render failed: no app")
            return
        }
        let plan = Scanner.scan(app, includeLow: false)
        let renderer = ImageRenderer(
            content: PlanView(plan: plan)
                .environmentObject(store)
                .frame(width: 840, height: 620)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("render: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// 渲染「彻底删除」确认弹窗，用于检查最危险的那个对话框
    @MainActor
    static func renderPermanentSheet(path: String, appName: String?) {
        let store = Store()
        let apps = Scanner.discoverApps()
        guard let app = apps.first(where: { appName == nil || $0.name.contains(appName!) }) ?? apps.first else {
            print("render failed: no app")
            return
        }
        store.plan = Scanner.scan(app, includeLow: true)
        let renderer = ImageRenderer(
            content: PermanentDeleteView()
                .environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("render: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// 渲染残留清理的确认弹窗
    @MainActor
    static func renderOrphanSheet(path: String) {
        let store = Store()
        store.orphans = OrphanScanner.scan(includeMedium: true)
        store.includeMediumOrphans = true
        for index in store.orphans.indices { store.orphans[index].selected = index < 6 }
        let renderer = ImageRenderer(
            content: OrphanDeleteView()
                .environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            print("render failed")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("render: \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }

    /// 用真实窗口渲染残留清理确认弹窗（ImageRenderer 不会给 ScrollView 排版，只能开窗看）
    static func snapshotOrphanSheet(path: String) {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let store = Store()
        store.orphans = OrphanScanner.scan(includeMedium: true)
        store.includeMediumOrphans = true
        for index in store.orphans.indices { store.orphans[index].selected = index < 6 }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "确认"
        window.contentView = NSHostingView(
            rootView: OrphanDeleteView()
                .environmentObject(store)
                .background(Color(nsColor: .windowBackgroundColor))
        )
        window.setFrame(NSRect(x: 120, y: 120, width: 500, height: 560), display: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))

        guard let cgImage = CGWindowListCreateImage(
            .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]
        ) else {
            print("snapshot failed")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
            print("snapshot(sheet): \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2))
    }

    private static func waitUntil(timeout: Double = 25, _ condition: () -> Bool) {        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
