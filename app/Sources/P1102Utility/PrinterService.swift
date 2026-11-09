import CCups
import Foundation
import IOKit

/// All CUPS and IOKit access. Calls block, so they run on this actor, never on the main thread.
actor PrinterService {
    static let nativeFilterMarker = "/Library/Printers/P1102Native/"

    // MARK: Snapshot

    func snapshot() -> PrinterSnapshot {
        let usb = Self.findUSBPrinter()
        let queues = findQueues()
        guard let queue = queues.first else {
            return PrinterSnapshot(queue: nil, otherQueues: [], usb: usb,
                                   status: usb == nil ? .offline : .unknown,
                                   stateMessage: "No print queue for the P1102 was found.",
                                   reasons: [], acceptingJobs: false, jobs: [])
        }
        let attrs = Self.ipp(op: IPP_OP_GET_PRINTER_ATTRIBUTES, resource: "/",
                             uri: ("printer-uri", Self.printerURI(queue.name)),
                             extra: [("requested-attributes", "all", IPP_TAG_KEYWORD)]).first ?? [:]
        let state = Int(attrs["printer-state"]?.first ?? "") ?? 0
        let reasons = (attrs["printer-state-reasons"] ?? []).filter { $0 != "none" }
        var message = attrs["printer-state-message"]?.first ?? ""
        let jobs = loadJobs(queue: queue.name)

        let status: PrinterStatus
        if usb == nil {
            status = .offline
            message = "The printer is not connected or is switched off."
        } else if state == 5 || reasons.contains(where: { $0.hasSuffix("-error") }) {
            status = .error
            if state == 5 && message.isEmpty { message = "The print queue is paused." }
        } else if state == 4 {
            status = .printing
        } else if state == 3 {
            status = .ready
        } else {
            status = .unknown
        }
        return PrinterSnapshot(queue: queue, otherQueues: queues.dropFirst().map(\.name), usb: usb,
                               status: status, stateMessage: message, reasons: reasons,
                               acceptingJobs: attrs["printer-is-accepting-jobs"]?.first == "true",
                               jobs: jobs)
    }

    // MARK: Queues and driver

    /// P1100-series queues, the native-driver one first, then the default one.
    private func findQueues() -> [PrinterQueue] {
        var dests: UnsafeMutablePointer<cups_dest_t>?
        let n = Int(cupsGetDests2(nil, &dests))
        defer { cupsFreeDests(Int32(n), dests) }
        guard let dests else { return [] }
        var result: [PrinterQueue] = []
        for i in 0..<n {
            let d = dests[i]
            guard d.instance == nil, let cname = d.name else { continue }
            func opt(_ key: String) -> String {
                cupsGetOption(key, d.num_options, d.options).map { String(cString: $0) } ?? ""
            }
            let name = String(cString: cname)
            let uri = opt("device-uri")
            let model = opt("printer-make-and-model")
            let isP1100 = uri.range(of: #"P110[2-9]"#, options: .regularExpression) != nil
                || model.contains("P1100") || model.contains("P1102")
            guard isP1100 else { continue }
            result.append(PrinterQueue(name: name, info: opt("printer-info").isEmpty ? name : opt("printer-info"),
                                       deviceURI: uri, isDefault: d.is_default != 0,
                                       driver: Self.driverInfo(queue: name)))
        }
        return result.sorted {
            ($0.driver.isNative ? 0 : 1, $0.isDefault ? 0 : 1) < ($1.driver.isNative ? 0 : 1, $1.isDefault ? 0 : 1)
        }
    }

    /// Reads the queue's PPD (world-readable in /etc/cups/ppd) to describe the driver.
    static func driverInfo(queue: String) -> DriverInfo {
        guard let data = FileManager.default.contents(atPath: "/etc/cups/ppd/\(queue).ppd"),
              let ppd = String(data: data, encoding: .isoLatin1) else { return .unknown }
        var info = DriverInfo.unknown
        for line in ppd.split(separator: "\n") {
            if line.hasPrefix("*NickName:") {
                info.nickName = line.split(separator: "\"").dropFirst().first.map(String.init) ?? info.nickName
            } else if line.hasPrefix("*cupsFilter"), line.contains("vnd.cups-raster"),
                      let path = line.split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\"\r")),
                      path.hasPrefix("/") {
                info.filterPath = path
            }
        }
        info.filterInstalled = info.filterPath.map { FileManager.default.isExecutableFile(atPath: $0) } ?? true
        info.isNative = info.filterPath?.hasPrefix(nativeFilterMarker) == true
        info.isGenericPCL = info.nickName.contains("PCL")
        info.supportsFineResolution = ppd.contains("\n*Resolutions 600x600dpi")
        info.supportsEconoMode = ppd.contains("\n*OpenUI *EconoMode")
        info.supportsDensity = ppd.contains("\n*OpenUI *pjlDensity")
        return info
    }

    // MARK: Jobs

    private func loadJobs(queue: String) -> [PrintJob] {
        let records = Self.ipp(op: IPP_OP_GET_JOBS, resource: "/",
                               uri: ("printer-uri", Self.printerURI(queue)),
                               extra: [("which-jobs", "all", IPP_TAG_KEYWORD),
                                       ("requested-attributes", "all", IPP_TAG_KEYWORD)],
                               group: IPP_TAG_JOB)
        let jobs: [PrintJob] = records.compactMap { r in
            guard let id = r["job-id"]?.first.flatMap({ Int($0) }),
                  let state = r["job-state"]?.first.flatMap({ Int($0) }).flatMap(PrintJob.State.init) else { return nil }
            // CUPS hides job-name from other connections (JobPrivateValues); the document name is public
            return PrintJob(id: id, title: r["job-name"]?.first ?? r["document-name-supplied"]?.first ?? "Untitled",
                            user: r["job-originating-user-name"]?.first ?? "",
                            state: state,
                            reasons: (r["job-state-reasons"] ?? []).filter { $0 != "none" },
                            message: r["job-printer-state-message"]?.first ?? "",
                            created: r["time-at-creation"]?.first.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) },
                            sizeKB: r["job-k-octets"]?.first.flatMap { Int($0) })
        }.sorted { $0.id > $1.id }
        // every active job, plus the five most recent finished ones (so failures can be retried)
        let active = jobs.filter(\.isActive)
        let finished = jobs.filter { !$0.isActive }.prefix(5)
        return active + finished
    }

    func print(file: URL, title: String, queue: String, options: [(String, String)]) throws -> Int {
        var num: Int32 = 0
        var opts: UnsafeMutablePointer<cups_option_t>?
        for (k, v) in options { num = cupsAddOption(k, v, num, &opts) }
        defer { cupsFreeOptions(num, opts) }
        let id = cupsPrintFile2(nil, queue, file.path, title, num, opts)
        guard id > 0 else { throw PrinterError(message: Self.lastError()) }
        return Int(id)
    }

    func cancel(job: Int, queue: String) throws {
        let status = cupsCancelJob2(nil, queue, Int32(job), 0)
        guard status.rawValue < 0x0400 else { throw PrinterError(message: Self.lastError()) }
    }

    /// Releases a held job, or restarts a stopped/canceled/aborted one (CUPS keeps job files).
    func retry(job: PrintJob) throws {
        // (CUPS 2.3.4 on macOS acknowledges Restart-Job with job-hold-until but leaves the job
        // canceled, so a restart always goes straight back to the queue.)
        let op = job.state == .held ? IPP_OP_RELEASE_JOB : IPP_OP_RESTART_JOB
        _ = Self.ipp(op: op, resource: "/jobs/", uri: ("job-uri", "ipp://localhost/jobs/\(job.id)"))
        guard cupsLastError().rawValue < 0x0400 else {
            throw PrinterError(message: "Could not retry job \(job.id): \(Self.lastError())")
        }
    }

    // MARK: IPP plumbing

    private static func printerURI(_ queue: String) -> String {
        "ipp://localhost/printers/" + (queue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? queue)
    }

    static func lastError() -> String {
        cupsLastErrorString().map { String(cString: $0) } ?? "Unknown CUPS error"
    }

    /// Sends one IPP request to the local scheduler and returns the attribute groups of the
    /// response (one dictionary per object of `group`).
    private static func ipp(op: ipp_op_t, resource: String, uri: (String, String),
                            extra: [(String, String, ipp_tag_t)] = [],
                            group: ipp_tag_t = IPP_TAG_PRINTER) -> [[String: [String]]] {
        guard let req = ippNewRequest(op) else { return [] }
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_URI, uri.0, nil, uri.1)
        ippAddString(req, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        for (name, value, tag) in extra { ippAddString(req, IPP_TAG_OPERATION, tag, name, nil, value) }
        guard let resp = cupsDoRequest(nil, req, resource) else { return [] }
        defer { ippDelete(resp) }

        var records: [[String: [String]]] = []
        var current: [String: [String]] = [:]
        var attr = ippFirstAttribute(resp)
        while let a = attr {
            if let cname = ippGetName(a), ippGetGroupTag(a) == group {
                var values: [String] = []
                for i in 0..<ippGetCount(a) {
                    switch ippGetValueTag(a) {
                    case IPP_TAG_INTEGER, IPP_TAG_ENUM:
                        values.append(String(ippGetInteger(a, i)))
                    case IPP_TAG_BOOLEAN:
                        values.append(ippGetBoolean(a, i) != 0 ? "true" : "false")
                    case IPP_TAG_TEXT, IPP_TAG_NAME, IPP_TAG_KEYWORD, IPP_TAG_URI, IPP_TAG_TEXTLANG,
                         IPP_TAG_NAMELANG, IPP_TAG_MIMETYPE, IPP_TAG_URISCHEME, IPP_TAG_CHARSET,
                         IPP_TAG_LANGUAGE:
                        if let s = ippGetString(a, i, nil) { values.append(String(cString: s)) }
                    default:
                        break
                    }
                }
                current[String(cString: cname)] = values
            } else if ippGetName(a) == nil, !current.isEmpty {
                records.append(current)     // separator between objects
                current = [:]
            }
            attr = ippNextAttribute(resp)
        }
        if !current.isEmpty { records.append(current) }
        return records
    }

    // MARK: USB (IOKit; no privileges needed)

    static func findUSBPrinter() -> USBInfo? {
        guard let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else { return nil }
        // a top-level idVendor key is ignored for already-matched devices; IOPropertyMatch is not
        match["IOPropertyMatch"] = ["idVendor": 0x03F0] // Hewlett-Packard
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            func prop(_ key: String) -> String? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            }
            if let name = prop("USB Product Name"), name.range(of: #"P110[2-9]"#, options: .regularExpression) != nil {
                return USBInfo(productName: name, serial: prop("USB Serial Number"))
            }
        }
        return nil
    }
}
