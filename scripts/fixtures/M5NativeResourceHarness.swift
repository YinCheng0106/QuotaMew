// Synthetic Release measurement entry point; copied over the app entry point in a temporary checkout only.
import AppKit
import Darwin
import Foundation

@main
struct M5NativeResourceMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = M5NativeResourceDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class M5NativeResourceDelegate: NSObject, NSApplicationDelegate {
    private var report: [String] = []
    private var reportURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--m5-resource-report"),
              arguments.indices.contains(index + 1) else {
            return URL(fileURLWithPath: "/tmp/QuotaMew-M5-native-resource.log")
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }
    private struct WeakPresentation {
        weak var window: NSWindow?
        weak var host: NSViewController?
    }
    private enum Failure: Error { case ownership, acquisition, resource }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run(); report.append("result=PASS") }
            catch { report.append("result=FAIL category=\(String(describing: error))") }
            try? report.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
            NSApplication.shared.terminate(nil)
        }
    }

    private func run() async throws {
        let name = "M5NativeResource-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        settings.setCodexAccountActivityEnabled(true)
        let source = try M5SyntheticSource()
        let store = ActivitySnapshotStore()
        let service = ActivityService(sources: [source], store: store, settings: settings)
        let model = ActivityModel(service: service, providerID: .codex, initiallyEnabled: true)
        let controller = ActivityWindowController(model: model, openSettings: {}, activate: {})
        var weakPresentations: [WeakPresentation] = []
        let baseline = try Sample.capture()
        report.append(baseline.line("idle"))
        try await sampleIdle("idle_cpu")
        autoreleasepool { controller.show() }
        await controller.waitForOpenRefresh()
        await loopTurn()
        autoreleasepool { controller.window?.contentView?.layoutSubtreeIfNeeded() }
        report.append(try Sample.capture().line("snapshot_window_open"))
        try await sampleIdle("window_cpu")
        for index in 1...100 {
            autoreleasepool {
                weakPresentations.append(WeakPresentation(window: controller.window,
                                                          host: controller.window?.contentViewController))
                controller.window?.close()
                controller.show()
                controller.window?.contentView?.layoutSubtreeIfNeeded()
            }
            await loopTurn()
            if index.isMultiple(of: 25) {
                report.append(try Sample.capture().line("windows_\(index)"))
                let counts = autoreleasepool {
                    (weakPresentations.filter { $0.window != nil }.count,
                     weakPresentations.filter { $0.host != nil }.count)
                }
                report.append("phase=ownership_\(index) windows=\(counts.0) hosts=\(counts.1)")
            }
        }
        guard await source.readCount == 1 else { throw Failure.acquisition }
        autoreleasepool { controller.window?.close() }
        await loopTurn()
        try await sampleIdle("closed_idle_cpu")
        let retained = autoreleasepool { weakPresentations.contains { $0.window != nil || $0.host != nil } }
        report.append("phase=closed_ownership released=\(!retained)")
        guard !retained else { throw Failure.ownership }
        let settled = try Sample.capture()
        report.append(settled.line("windows_settled"))
        for index in 1...100 {
            try await model.refresh()
            if index.isMultiple(of: 25) { report.append(try Sample.capture().line("refreshes_\(index)")) }
        }
        guard await source.readCount == 101 else { throw Failure.acquisition }
        let after = try Sample.capture()
        guard after.fds <= settled.fds + 4, after.threads <= settled.threads + 8,
              after.children == baseline.children else { throw Failure.resource }
        controller.teardown()
        await service.shutdown()
        report.append(try Sample.capture().line("teardown"))
        report.append("source_reads=101 window_reopen_reads=0")
    }

    private func sampleIdle(_ phase: String) async throws {
        let start = try Sample.capture()
        let clock = ContinuousClock.now
        try await Task.sleep(for: .seconds(2))
        let end = try Sample.capture()
        let duration = clock.duration(to: .now)
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        report.append("phase=\(phase) percent=\((end.cpu - start.cpu) / seconds * 100)")
    }

    private func loopTurn() async {
        await withCheckedContinuation { continuation in
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              false, 0) { _, _ in continuation.resume() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        }
    }

    private struct Sample {
        let rss: UInt64
        let fds: Int
        let threads: Int
        let children: Int
        let cpu: Double
        static func capture() throws -> Self {
            var task = proc_taskinfo()
            guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
                    == MemoryLayout<proc_taskinfo>.size else { throw Failure.resource }
            var fdBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
            let bytes = fdBuffer.withUnsafeMutableBytes {
                proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0, bytes < fdBuffer.count * MemoryLayout<proc_fdinfo>.size else { throw Failure.resource }
            var childBuffer = [pid_t](repeating: 0, count: 128)
            let childBytes = childBuffer.withUnsafeMutableBytes { proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count)) }
            guard childBytes >= 0 else { throw Failure.resource }
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.resource }
            return Self(rss: task.pti_resident_size, fds: Int(bytes) / MemoryLayout<proc_fdinfo>.size,
                        threads: Int(task.pti_threadnum), children: childBuffer.filter { $0 > 0 }.count,
                        cpu: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6)
        }
        func line(_ phase: String) -> String {
            "phase=\(phase) rss_bytes=\(rss) fds=\(fds) threads=\(threads) children=\(children)"
        }
    }
}

actor M5SyntheticSource: TokenActivitySource {
    nonisolated let id = ProviderID.codex
    private(set) var readCount = 0
    private let snapshot: ProviderActivitySnapshot
    init() throws {
        let anchor = try ProviderCalendarDate("2026-10-02")
        let buckets = try (0..<30).map { offset in
            try ActivityBucket(sourceDate: anchor.addingDays(-offset), reportedTokens: offset == 1 ? 0 : 2100)
        }
        snapshot = try ProviderActivitySnapshot(providerID: .codex, buckets: buckets,
                                               capturedAt: .distantPast, source: .synthetic)
    }
    func fetchActivity() async throws -> ActivityFetchResult {
        readCount += 1
        return .snapshot(snapshot)
    }
}
