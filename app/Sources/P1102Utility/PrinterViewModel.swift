import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PrinterViewModel: ObservableObject {
    @Published private(set) var snapshot = PrinterSnapshot.empty
    @Published private(set) var loaded = false
    @Published private(set) var refreshing = false
    @Published var notice: Notice?

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    private let service = PrinterService()
    private var noticeTask: Task<Void, Never>?

    var testPageURL: URL? { Bundle.main.url(forResource: "TestPage", withExtension: "pdf") }

    /// Polls CUPS and USB every two seconds while the window is open.
    func monitor() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        refreshing = true
        var s = await service.snapshot()
        // CUPS sometimes returns a finished job without job-name/time-at-creation; keep what we knew
        let known = Dictionary(snapshot.jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in s.jobs.indices where s.jobs[i].created == nil {
            if let old = known[s.jobs[i].id], old.created != nil {
                s.jobs[i].title = old.title
                s.jobs[i].created = old.created
            }
        }
        if s != snapshot { snapshot = s }
        loaded = true
        refreshing = false
    }

    // MARK: Actions

    func chooseAndPrintDocument() {
        let panel = NSOpenPanel()
        panel.title = "Print Document"
        panel.prompt = "Print"
        panel.allowedContentTypes = [.pdf, .image, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await print(url, title: url.lastPathComponent, usePageRanges: true) }
    }

    func printTestPage() {
        guard let url = testPageURL else { return show("The test page is missing from the app bundle.", error: true) }
        Task { await print(url, title: "P1102 test page", usePageRanges: false) }
    }

    func print(_ url: URL, title: String, usePageRanges: Bool) async {
        guard let queue = snapshot.queue else { return show("No print queue for the P1102.", error: true) }
        let options = PrintOptions.current()
        if usePageRanges, PrintOptions.normalizedPageRanges(options.pageRanges) == nil {
            return show("Pages: use numbers and ranges like 1-3, 5.", error: true)
        }
        do {
            let id = try await service.print(file: url, title: title, queue: queue.name,
                                              options: options.cupsOptions(driver: queue.driver,
                                                                           includePageRanges: usePageRanges))
            show(snapshot.usb == nil ? "“\(title)” queued as job \(id). It prints when the printer is connected."
                                     : "“\(title)” sent as job \(id).")
        } catch {
            show(error.localizedDescription, error: true)
        }
        await refresh()
    }

    func cancel(_ job: PrintJob) {
        guard let queue = snapshot.queue else { return }
        Task {
            do { try await service.cancel(job: job.id, queue: queue.name); show("Job \(job.id) canceled.") }
            catch { show(error.localizedDescription, error: true) }
            await refresh()
        }
    }

    func retry(_ job: PrintJob) {
        Task {
            do { try await service.retry(job: job); show("Job \(job.id) will print again.") }
            catch { show(error.localizedDescription, error: true) }
            await refresh()
        }
    }

    /// Opens the macOS print queue window for the printer if macOS has created one,
    /// otherwise Printers & Scanners settings.
    func openSystemQueue() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Printers")
        if let info = snapshot.queue?.info {
            let app = dir.appending(path: "\(info).app")
            if FileManager.default.fileExists(atPath: app.path) {
                NSWorkspace.shared.open(app)
                return
            }
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func show(_ text: String, error: Bool = false) {
        notice = Notice(text: text, isError: error)
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(error ? 8 : 5))
            if !Task.isCancelled { notice = nil }
        }
    }
}
