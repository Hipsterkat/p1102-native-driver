import Foundation

/// `P1102 Printer --selftest`: exercises the real CUPS queue without printing anything.
/// The test job is submitted on hold, so it never reaches the printer, and is canceled at the end.
enum SelfTest {
    static func runAndExit() {
        Task {
            let failures = await run()
            print(failures == 0 ? "\nSELFTEST PASSED" : "\nSELFTEST FAILED: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        dispatchMain()
    }

    private static func run() async -> Int {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok { failures += 1 }
        }
        let service = PrinterService()

        print("== options")
        check(PrintOptions.normalizedPageRanges(" 1-3, 5 ") == "1-3,5", "page ranges normalized")
        check(PrintOptions.normalizedPageRanges("") == "", "empty page range = all pages")
        check(PrintOptions.normalizedPageRanges("3-1") == nil && PrintOptions.normalizedPageRanges("a") == nil
              && PrintOptions.normalizedPageRanges("0") == nil, "invalid page ranges rejected")

        print("== printer")
        let s = await service.snapshot()
        guard let queue = s.queue else {
            check(false, "P1102 queue found")
            return failures
        }
        check(true, "queue \(queue.name) (\(queue.info))")
        check(queue.driver.isNative && queue.driver.filterInstalled, "native driver: \(queue.driver.nickName)")
        check(queue.driver.supportsFineResolution && queue.driver.supportsEconoMode && queue.driver.supportsDensity,
              "PPD options: Resolutions, EconoMode, pjlDensity")
        print("  info  USB: \(s.usb.map { "\($0.productName) serial \($0.serial ?? "?")" } ?? "not connected")")
        print("  info  status: \(s.status.title) \(s.stateMessage) reasons=\(s.reasons) accepting=\(s.acceptingJobs)")
        check(s.acceptingJobs, "queue accepts jobs")

        print("== jobs (held test job, nothing is printed)")
        guard let page = Bundle.main.url(forResource: "TestPage", withExtension: "pdf")
                ?? CommandLine.arguments.drop(while: { $0 != "--selftest" }).dropFirst().first
                    .map(URL.init(fileURLWithPath:))
        else {
            check(false, "test page available")
            return failures
        }
        var opts = PrintOptions()
        opts.paper = .a4; opts.quality = .fine; opts.copies = 2; opts.pageRanges = "1"
        opts.econoMode = true; opts.density = 4
        let cups = opts.cupsOptions(driver: queue.driver, includePageRanges: true)
        check(cups.contains { $0 == ("Resolutions", "600x600dpi") } && cups.contains { $0 == ("copies", "2") }
              && cups.contains { $0 == ("page-ranges", "1") } && cups.contains { $0 == ("EconoMode", "True") }
              && cups.contains { $0 == ("pjlDensity", "4") }, "options mapped to PPD/IPP names")
        let id: Int
        do {
            id = try await service.print(file: page, title: "P1102 selftest (held)", queue: queue.name,
                                         options: cups + [("job-hold-until", "indefinite")])
            check(true, "submitted held job \(id)")
        } catch {
            check(false, "submit job: \(error.localizedDescription)")
            return failures
        }
        func job() async -> PrintJob? { await service.snapshot().jobs.first { $0.id == id } }

        var j = await job()
        check(j?.state == .held, "job \(id) listed as held (\(j?.state.title ?? "missing"))")
        do { try await service.cancel(job: id, queue: queue.name) } catch { check(false, "cancel: \(error)") }
        j = await job()
        check(j?.state == .canceled, "job \(id) canceled (\(j?.state.title ?? "missing"))")
        // A restarted job goes back to the printer, so only test it while nothing can print.
        if let canceled = j, PrinterService.findUSBPrinter() == nil {
            do { try await service.retry(job: canceled) } catch { check(false, "\(error.localizedDescription)") }
            j = await job()
            check(j.map { $0.isActive } == true, "retry restarts the canceled job (\(j?.state.title ?? "missing"))")
            do { try await service.cancel(job: id, queue: queue.name) } catch { check(false, "cancel: \(error)") }
            j = await job()
            check(j?.state == .canceled, "cleaned up: job \(id) canceled again")
        } else {
            print("  skip  retry test (printer connected: a restarted job would print)")
        }
        return failures
    }
}
