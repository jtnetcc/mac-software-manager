import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct MacAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--orphans") {
            let all = CommandLine.arguments.count > index + 1 && CommandLine.arguments[index + 1] == "all"
            SelfTest.dumpOrphans(includeMedium: all)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-orphan-sheet"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            Snapshot.snapshotOrphanSheet(path: path)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-orphan-sheet"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            MainActor.assumeIsolated {
                Snapshot.renderOrphanSheet(path: path)
            }
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-perm"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let name = CommandLine.arguments.count > index + 2 ? CommandLine.arguments[index + 2] : nil
            MainActor.assumeIsolated {
                Snapshot.renderPermanentSheet(path: path, appName: name)
            }
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let name = CommandLine.arguments.count > index + 2 ? CommandLine.arguments[index + 2] : nil
            MainActor.assumeIsolated {
                Snapshot.renderDetail(path: path, appName: name)
            }
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let name = CommandLine.arguments.count > index + 2 ? CommandLine.arguments[index + 2] : nil
            Snapshot.run(path: path, appName: name)
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-orphan"),
           CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            let mode = CommandLine.arguments.count > index + 2 ? CommandLine.arguments[index + 2] : nil
            Snapshot.run(path: path, appName: nil, mode: mode ?? "orphan")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Mac软件管家") {
            ContentView()
                .environmentObject(store)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
