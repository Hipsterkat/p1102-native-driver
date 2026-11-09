import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: PrinterViewModel

    var body: some View {
        ScrollView {
            GlassGroup(spacing: 14) {
                VStack(spacing: 14) {
                    OverviewCard()
                    ActionsRow()
                    SettingsCard()
                    QueueCard()
                }
                .padding(18)
            }
        }
        .scrollIndicators(.never)
        .softTopScrollEdge()
        .frame(width: 440)
        .frame(minHeight: 520, idealHeight: 800)
        .overlay(alignment: .bottom) { NoticeView() }
        .translucentWindowBackground()
        .task { await model.monitor() }
    }
}

// MARK: - Overview

private struct OverviewCard: View {
    @EnvironmentObject private var model: PrinterViewModel

    var body: some View {
        let s = model.snapshot
        Card {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "printer.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
                    .frame(width: 58, height: 58)
                    .glassSurface(cornerRadius: 16)
                VStack(alignment: .leading, spacing: 5) {
                    Text("HP LaserJet Professional P1102")
                        .font(.headline)
                    if model.loaded {
                        StatusPill(status: s.status)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            if let detail = statusDetail(s), !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(s.status == .error ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                InfoRow(label: "Connection", value: connectionText(s),
                        tint: s.usb == nil ? .secondary : .primary)
                InfoRow(label: "Queue", value: queueText(s), tint: .primary)
                InfoRow(label: "Driver", value: driverText(s), tint: driverTint(s))
            }
            .font(.callout)
        }
    }

    private func statusDetail(_ s: PrinterSnapshot) -> String? {
        if !s.stateMessage.isEmpty, s.status != .ready { return s.stateMessage }
        return s.reasons.compactMap(Self.describe).first
    }

    /// Plain-language versions of the IPP printer-state-reasons this printer reports.
    static func describe(_ reason: String) -> String? {
        let base = reason.replacingOccurrences(of: #"-(error|warning|report)$"#, with: "", options: .regularExpression)
        switch base {
        case "media-empty", "media-needed": return "Load paper into the input tray."
        case "media-jam": return "Paper jam: open the cartridge door and remove the paper."
        case "cover-open": return "The cartridge door is open."
        case "toner-empty": return "Toner cartridge missing or not seated."
        case "toner-low": return "Toner is low."
        case "offline": return "The printer is offline."
        case "paused": return "The print queue is paused."
        default: return nil
        }
    }

    private func connectionText(_ s: PrinterSnapshot) -> String {
        guard let usb = s.usb else { return "Disconnected" }
        return "USB · Connected" + (usb.serial.map { " · \($0.suffix(8))" } ?? "")
    }

    private func queueText(_ s: PrinterSnapshot) -> String {
        guard let q = s.queue else { return "Not set up" }
        return q.name + (q.isDefault ? " (default)" : "")
    }

    private func driverText(_ s: PrinterSnapshot) -> String {
        guard let d = s.queue?.driver else { return "—" }
        if d.isNative {
            guard d.filterInstalled else { return "Native driver files missing" }
            let version = d.nickName.range(of: #"[0-9]+(\.[0-9]+)+$"#, options: .regularExpression)
                .map { " " + d.nickName[$0] } ?? ""
            return "Native\(version) · Apple Silicon"
        }
        if d.isGenericPCL { return "Generic PCL — cannot print on this model" }
        return d.nickName
    }

    private func driverTint(_ s: PrinterSnapshot) -> Color {
        guard let d = s.queue?.driver else { return .secondary }
        return d.isNative && d.filterInstalled ? .primary : .orange
    }
}

private struct InfoRow: View {
    var label: String
    var value: String
    var tint: Color

    var body: some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).foregroundStyle(tint).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

private struct StatusPill: View {
    var status: PrinterStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(status.title).font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityLabel("Status: \(status.title)")
    }

    private var color: Color {
        switch status {
        case .ready: .green
        case .printing: .blue
        case .error: .orange
        case .offline, .unknown: .gray
        }
    }
}

// MARK: - Quick actions

private struct ActionsRow: View {
    @EnvironmentObject private var model: PrinterViewModel

    var body: some View {
        let ready = model.snapshot.queue != nil
        HStack(spacing: 10) {
            ActionButton(title: "Print…", symbol: "doc.richtext", prominent: true) {
                model.chooseAndPrintDocument()
            }
            .disabled(!ready)
            .keyboardShortcut("p")
            ActionButton(title: "Test Page", symbol: "doc.text.magnifyingglass") { model.printTestPage() }
                .disabled(!ready)
            ActionButton(title: "Queue", symbol: "list.bullet.rectangle") { model.openSystemQueue() }
            ActionButton(title: "Refresh", symbol: "arrow.clockwise") { Task { await model.refresh() } }
                .keyboardShortcut("r")
        }
    }
}

private struct ActionButton: View {
    var title: String
    var symbol: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        .glassButtonStyle(prominent: prominent)
        .controlSize(.large)
        .help(title)
    }
}

// MARK: - Settings

private struct SettingsCard: View {
    @EnvironmentObject private var model: PrinterViewModel
    @AppStorage(PrintOptions.Key.paper) private var paper = PrintOptions.Paper.a4
    @AppStorage(PrintOptions.Key.quality) private var quality = PrintOptions.Quality.standard
    @AppStorage(PrintOptions.Key.copies) private var copies = 1
    @AppStorage(PrintOptions.Key.pageRanges) private var pageRanges = ""
    @AppStorage(PrintOptions.Key.econoMode) private var econoMode = false
    @AppStorage(PrintOptions.Key.density) private var density = 3
    @AppStorage(PrintOptions.Key.twoSided) private var twoSided = false
    // AppStorage rather than @State: the @State macro plugin ships with Xcode, not the CLT
    @AppStorage("showAdvanced") private var showAdvanced = false

    var body: some View {
        let driver = model.snapshot.queue?.driver ?? .unknown
        Card(title: "Print Settings") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Paper")
                    Picker("Paper", selection: $paper) {
                        ForEach(PrintOptions.Paper.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                GridRow {
                    label("Quality")
                    Picker("Quality", selection: $quality) {
                        ForEach(PrintOptions.Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .disabled(!driver.supportsFineResolution)
                }
                GridRow {
                    label("Copies")
                    Stepper(value: $copies, in: 1...99) {
                        Text("\(copies)").monospacedDigit().frame(minWidth: 24, alignment: .leading)
                    }
                }
                GridRow {
                    label("Pages")
                    HStack(spacing: 6) {
                        TextField("All", text: $pageRanges, prompt: Text("All pages"))
                            .textFieldStyle(.roundedBorder)
                        if PrintOptions.normalizedPageRanges(pageRanges) == nil {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                                .help("Use numbers and ranges, e.g. 1-3, 5")
                        }
                    }
                }
            }
            .font(.callout)

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        label("Density")
                        Picker("Density", selection: $density) {
                            ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .disabled(!driver.supportsDensity)
                    }
                    GridRow {
                        label("Toner")
                        Toggle("EconoMode (saves toner)", isOn: $econoMode)
                            .disabled(!driver.supportsEconoMode)
                    }
                    GridRow {
                        label("Sides")
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Two-sided (manual)", isOn: $twoSided)
                            Text("Backs print first; then put the stack back printed side down.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

// MARK: - Queue

private struct QueueCard: View {
    @EnvironmentObject private var model: PrinterViewModel

    var body: some View {
        let jobs = model.snapshot.jobs
        let active = jobs.filter(\.isActive).count
        Card(title: "Print Queue", trailing: active == 0 ? nil : "\(active) active") {
            if jobs.isEmpty {
                Text(model.loaded ? "No print jobs" : "Loading…")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                VStack(spacing: 8) {
                    ForEach(jobs) { JobRow(job: $0) }
                }
            }
        }
    }
}

private struct JobRow: View {
    @EnvironmentObject private var model: PrinterViewModel
    var job: PrintJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let p = job.progress {
                    ProgressView(value: p).controlSize(.small)
                } else if job.state == .processing {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if job.canRetry {
                Button { model.retry(job) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(job.state == .held ? "Release job" : "Print again")
            }
            if job.canCancel {
                Button { model.cancel(job) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel job")
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = ["Job \(job.id)", job.state.title]
        if job.isActive, !job.message.isEmpty, job.progress == nil { parts.append(job.message) }
        if let d = job.created { parts.append(d.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private var icon: String {
        switch job.state {
        case .processing: "printer.dotmatrix.fill"
        case .pending: "clock"
        case .held, .stopped: "pause.circle"
        case .completed: "checkmark.circle"
        case .canceled: "xmark.circle"
        case .aborted: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch job.state {
        case .processing: .blue
        case .aborted, .stopped: .orange
        case .completed: .green
        default: .secondary
        }
    }
}

// MARK: - Notices

private struct NoticeView: View {
    @EnvironmentObject private var model: PrinterViewModel

    var body: some View {
        if let n = model.notice {
            Label(n.text, systemImage: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(n.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .glassSurface(cornerRadius: 14)
                .padding(14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { model.notice = nil }
        }
    }
}
