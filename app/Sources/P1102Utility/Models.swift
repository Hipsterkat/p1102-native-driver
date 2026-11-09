import Foundation

/// The CUPS queue that drives the P1102, as found on this Mac.
struct PrinterQueue: Equatable, Sendable {
    var name: String            // CUPS queue name, e.g. HP_LaserJet_P1102_Native
    var info: String            // human-readable description
    var deviceURI: String
    var isDefault: Bool
    var driver: DriverInfo
}

struct DriverInfo: Equatable, Sendable {
    var nickName: String        // *NickName from the queue's PPD
    var filterPath: String?     // absolute raster filter path, nil for built-in filters
    var filterInstalled: Bool
    var isNative: Bool          // our rastertop1102 driver
    var isGenericPCL: Bool      // the incompatible "HP LaserJet Series PCL 4/5" driver
    var supportsFineResolution: Bool
    var supportsEconoMode: Bool
    var supportsDensity: Bool

    static let unknown = DriverInfo(nickName: "Unknown", filterPath: nil, filterInstalled: false,
                                    isNative: false, isGenericPCL: false, supportsFineResolution: false,
                                    supportsEconoMode: false, supportsDensity: false)
}

struct USBInfo: Equatable, Sendable {
    var productName: String
    var serial: String?
}

enum PrinterStatus: Equatable, Sendable {
    case ready, printing, offline, error, unknown

    var title: String {
        switch self {
        case .ready: "Ready"
        case .printing: "Printing"
        case .offline: "Offline"
        case .error: "Error"
        case .unknown: "Unknown"
        }
    }
}

/// One refresh of everything the window shows; produced off the main thread.
struct PrinterSnapshot: Equatable, Sendable {
    var queue: PrinterQueue?
    var otherQueues: [String]
    var usb: USBInfo?
    var status: PrinterStatus
    var stateMessage: String    // printer-state-message, or our own explanation
    var reasons: [String]       // printer-state-reasons without "none"
    var acceptingJobs: Bool
    var jobs: [PrintJob]

    static let empty = PrinterSnapshot(queue: nil, otherQueues: [], usb: nil, status: .unknown,
                                       stateMessage: "", reasons: [], acceptingJobs: false, jobs: [])
}

struct PrintJob: Identifiable, Equatable, Sendable {
    enum State: Int, Sendable {
        case pending = 3, held, processing, stopped, canceled, aborted, completed

        var title: String {
            switch self {
            case .pending: "Waiting"
            case .held: "On hold"
            case .processing: "Printing"
            case .stopped: "Stopped"
            case .canceled: "Canceled"
            case .aborted: "Failed"
            case .completed: "Sent to printer"
            }
        }
    }

    var id: Int
    var title: String
    var user: String
    var state: State
    var reasons: [String]
    var message: String
    var created: Date?
    var sizeKB: Int?

    var isActive: Bool { [.pending, .held, .processing, .stopped].contains(state) }
    var canCancel: Bool { isActive }
    var canRetry: Bool { [.held, .stopped, .canceled, .aborted].contains(state) }

    /// Progress reported by the filter ("Printing page 1, 40% complete..."), when processing.
    var progress: Double? {
        guard state == .processing,
              let r = message.range(of: #"(\d{1,3})% complete"#, options: .regularExpression) else { return nil }
        let digits = message[r].prefix { $0.isNumber }
        return Double(digits).map { min($0, 100) / 100 }
    }
}

/// Print options; persisted in UserDefaults and mapped to the native driver's PPD options.
struct PrintOptions: Sendable {
    enum Paper: String, CaseIterable, Identifiable, Sendable {
        case a4 = "A4", letter = "Letter"
        var id: String { rawValue }
    }

    enum Quality: String, CaseIterable, Identifiable, Sendable {
        case standard = "600x400dpi"   // PPD "FastRes 600" (default)
        case fine = "600x600dpi"       // PPD "FastRes 1200"
        var id: String { rawValue }
        var title: String { self == .standard ? "FastRes 600" : "FastRes 1200" }
    }

    var paper: Paper = .a4
    var quality: Quality = .standard
    var copies: Int = 1
    var pageRanges: String = ""
    var econoMode = false
    var density = 3
    var twoSided = false

    enum Key {
        static let paper = "paper", quality = "quality", copies = "copies", pageRanges = "pageRanges",
                   econoMode = "econoMode", density = "density", twoSided = "twoSided"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.paper: Paper.a4.rawValue, Key.quality: Quality.standard.rawValue, Key.copies: 1,
            Key.pageRanges: "", Key.econoMode: false, Key.density: 3, Key.twoSided: false,
        ])
    }

    static func current(_ d: UserDefaults = .standard) -> PrintOptions {
        PrintOptions(paper: Paper(rawValue: d.string(forKey: Key.paper) ?? "") ?? .a4,
                     quality: Quality(rawValue: d.string(forKey: Key.quality) ?? "") ?? .standard,
                     copies: min(max(d.integer(forKey: Key.copies), 1), 99),
                     pageRanges: d.string(forKey: Key.pageRanges) ?? "",
                     econoMode: d.bool(forKey: Key.econoMode),
                     density: min(max(d.integer(forKey: Key.density), 1), 5),
                     twoSided: d.bool(forKey: Key.twoSided))
    }

    /// "1-3, 5" -> "1-3,5"; nil if the text is not a valid page range list. Empty means all pages.
    static func normalizedPageRanges(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }
        if compact.isEmpty { return "" }
        guard compact.range(of: #"^\d+(-\d+)?(,\d+(-\d+)?)*$"#, options: .regularExpression) != nil
        else { return nil }
        for part in compact.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            if bounds.contains(0) || (bounds.count == 2 && bounds[0] > bounds[1]) { return nil }
        }
        return compact
    }

    /// CUPS job options for the given driver.
    func cupsOptions(driver: DriverInfo, includePageRanges: Bool) -> [(String, String)] {
        var o: [(String, String)] = [("PageSize", paper.rawValue), ("copies", String(copies))]
        if driver.supportsFineResolution { o.append(("Resolutions", quality.rawValue)) }
        if driver.supportsEconoMode { o.append(("EconoMode", econoMode ? "True" : "False")) }
        if driver.supportsDensity { o.append(("pjlDensity", String(density))) }
        o.append(("sides", twoSided ? "two-sided-long-edge" : "one-sided"))
        if includePageRanges, let r = Self.normalizedPageRanges(pageRanges), !r.isEmpty {
            o.append(("page-ranges", r))
        }
        return o
    }
}

struct PrinterError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
