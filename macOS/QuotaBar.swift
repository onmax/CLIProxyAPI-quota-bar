import AppKit
import SwiftUI

struct ResetCredit: Decodable, Identifiable {
    let id: String
    let expires: Double
    let granted: Double?
    let supported: Bool
}
struct Account: Decodable, Identifiable {
    let id: String
    let name: String
    let remaining: Double?
    let weeklyReset: Double?
    let available: Int?
    let applicable: Int?
    let credits: [ResetCredit]
    let error: String?
    let creditsError: String?
    let holdReason: String?
    let eligible: Bool
    let revision: String
    var nextCredit: ResetCredit? { credits.first(where: { $0.supported }) }
}
struct Snapshot: Decodable {
    let updated: Double
    let accounts: [Account]
    let total: Double?
    let capacity: Int
    let recommended: String?
    let dashboard: String
    let pending: String?
}
struct Reply: Decodable {
    let error: String?
    let message: String?
    let snapshot: Snapshot?
}

func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
func dateText(_ value: Double) -> String {
    Date(timeIntervalSince1970: value).formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
func timeLeft(_ value: Double) -> String {
    let minutes = Int((value - Date().timeIntervalSince1970) / 60)
    if minutes <= 0 { return "now" }
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 1440 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes / 1440)d \((minutes % 1440) / 60)h"
}

@MainActor final class Store: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var busy = false
    @Published var message: String?
    @Published var failed = false
    @Published var resetView = false
    @Published var selectedID: String?
    var updated: (() -> Void)?
    private var timer: Timer?
    var selected: Account? { snapshot?.accounts.first { $0.id == selectedID } }
    var stale: Bool { snapshot.map { Date().timeIntervalSince1970 - $0.updated > 600 } ?? true }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        guard !busy else { return }
        run("summary")
    }
    func preview(_ account: Account? = nil) {
        resetView = true
        selectedID = account?.id ?? snapshot?.recommended
        // Opening a preview can only read data.
        refresh()
    }
    func confirm() {
        guard !busy, let account = selected, account.eligible, !stale, snapshot?.pending == nil else { return }
        let command = ["account": account.id, "revision": account.revision, "requestID": UUID().uuidString]
        guard let input = try? JSONSerialization.data(withJSONObject: command) else { return }
        run("reset", input: input)
    }
    private func run(_ operation: String, input: Data? = nil) {
        busy = true
        message = nil
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    guard let script = Bundle.main.url(forResource: "pool", withExtension: "py") else {
                        throw NSError(domain: "QuotaBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing proxy client"])
                    }
                    process.arguments = [script.path, operation]
                    let output = Pipe()
                    let stdin = Pipe()
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = stdin
                    try process.run()
                    if let input { stdin.fileHandleForWriting.write(input) }
                    try? stdin.fileHandleForWriting.close()
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return result
                }.value
                if let reply = try? JSONDecoder().decode(Reply.self, from: data), let error = reply.error {
                    message = error
                    failed = true
                } else if operation == "summary" {
                    let fresh = try JSONDecoder().decode(Snapshot.self, from: data)
                    snapshot = fresh
                    if selectedID == nil { selectedID = fresh.recommended }
                    failed = false
                } else {
                    let reply = try JSONDecoder().decode(Reply.self, from: data)
                    snapshot = reply.snapshot ?? snapshot
                    message = reply.message ?? "Reset completed."
                    resetView = false
                    selectedID = reply.snapshot?.recommended
                    failed = false
                }
            } catch {
                message = operation == "reset"
                    ? "The reset result is uncertain. Refresh and check the dashboard before trying again."
                    : "Could not read the proxy. Check the connection, then refresh."
                failed = true
            }
            busy = false
            updated?()
        }
    }
    func openDashboard() {
        guard let value = snapshot?.dashboard, let url = URL(string: value), ["https", "http"].contains(url.scheme) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct QuotaTrack: View {
    let value: Double
    var capacity: Double = 100
    let color: Color
    var track: Color = Color.primary.opacity(0.09)
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if value > 0 && capacity > 0 {
                    Rectangle().fill(color)
                        .frame(width: geometry.size.width * min(1, value / capacity))
                }
            }.clipShape(Capsule())
        }.frame(height: 4)
            .accessibilityLabel("Quota remaining")
            .accessibilityValue(percent(value))
    }
}

struct QuotaView: View {
    @ObservedObject var store: Store
    private let blue = Color(red: 0.02, green: 0.36, blue: 0.85)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "terminal.fill").font(.system(size: 19)).foregroundStyle(blue)
                Text("Codex").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.busy).help("Refresh quota")
                Menu {
                    Button("Open dashboard", action: store.openDashboard)
                    Divider()
                    Button("Quit Quota Bar") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("More options")
            }.padding(.horizontal, 16).padding(.vertical, 12)
            HStack(spacing: 4) {
                tab("Overview", symbol: "square.grid.2x2", active: !store.resetView) { store.resetView = false }
                tab("Resets", symbol: "arrow.counterclockwise", active: store.resetView) { store.preview() }
            }.padding(3).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14).padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let s = store.snapshot {
                        if store.resetView { resetPanel(s) } else { overview(s) }
                    } else {
                        VStack(spacing: 10) {
                            if store.busy { ProgressView() }
                            Text(store.busy ? "Reading your account pool…" : "Your pool is unavailable")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    }
                    if let message = store.message {
                        Label(message, systemImage: store.failed ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.system(size: 11)).foregroundStyle(store.failed ? .orange : .green)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(.horizontal, 14).padding(.bottom, 10)
            }.scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack(spacing: 5) {
                if store.busy { ProgressView().controlSize(.mini) }
                Circle().fill(store.stale || store.failed ? .orange : .green).frame(width: 4, height: 4)
                Text(store.busy ? "Refreshing…" : (store.stale || store.failed ? "Last known data" : "Updated"))
                if let s = store.snapshot { Text(Date(timeIntervalSince1970: s.updated), style: .time).monospacedDigit() }
                Spacer()
                Button("Dashboard", action: store.openDashboard).buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9)
        }.frame(width: 400, height: 620)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tab(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(active ? blue : .clear, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(active ? Color.white : Color.secondary)
        }.buttonStyle(.plain)
    }
    private func overview(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Weekly remaining").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(s.accounts.count) Pro accounts").font(.system(size: 10)).opacity(0.8)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(percent(s.total)).font(.system(size: 35, weight: .semibold)).monospacedDigit()
                    Text("/ \(s.capacity)%").font(.system(size: 16)).opacity(0.65)
                    Spacer()
                    let count = s.accounts.compactMap(\.available)
                    Text(count.count == s.accounts.count ? "\(count.reduce(0, +)) resets saved" : "Resets unknown")
                        .font(.system(size: 10)).opacity(0.85)
                }
                QuotaTrack(value: s.total ?? 0, capacity: Double(s.capacity), color: .white, track: .white.opacity(0.2))
            }.foregroundStyle(.white).padding(14).background(blue, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Accounts").fontWeight(.semibold)
                Spacer()
                Text("Weekly remaining")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(s.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(account)
                    if index < s.accounts.count - 1 { Divider().padding(.horizontal, 12) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            if let recommended = s.accounts.first(where: { $0.id == s.recommended }), let credit = recommended.nextCredit {
                Button { store.preview(recommended) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise").foregroundStyle(blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Next reset: \(recommended.name)").font(.system(size: 11, weight: .semibold))
                            Text("\(percent(recommended.remaining)) left · earliest expiry in \(timeLeft(credit.expires))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    }.padding(10).background(blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            } else {
                Text(s.pending ?? "No account needs an eligible reset right now.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
    private func accountRow(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(a.name).font(.system(size: 12, weight: .semibold))
                Button { store.preview(a) } label: {
                    Text(a.available.map { "\($0) resets ›" } ?? "Resets ?")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Show reset grants and expiry dates")
                Spacer()
                Text(percent(a.remaining)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            QuotaTrack(value: a.remaining ?? 0, color: (a.remaining ?? 0) > 10 ? blue : .orange)
            HStack(spacing: 5) {
                if let reset = a.weeklyReset {
                    Text("Renews in \(timeLeft(reset))").help(dateText(reset))
                } else { Text(a.error ?? "Renewal unknown") }
                Spacer(minLength: 0)
                if let credit = a.nextCredit {
                    Text("Reset expires \(Date(timeIntervalSince1970: credit.expires).formatted(.dateTime.month(.abbreviated).day()))")
                        .help("\(dateText(credit.expires)) · \(timeLeft(credit.expires)) left")
                } else { Text(a.creditsError ?? "No saved resets") }
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func creditRow(_ c: ResetCredit) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Expires \(dateText(c.expires))").font(.system(size: 10, weight: .medium))
                Text(c.granted.map { "Granted \(dateText($0))" } ?? "Grant date unavailable").font(.system(size: 9)).foregroundStyle(.secondary)
                if !c.supported { Text("Not supported by this plan").font(.system(size: 9)).foregroundStyle(.orange) }
            }
            Spacer(minLength: 0)
            Text(timeLeft(c.expires)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
    private func resetPanel(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Use a saved reset").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("Account", selection: $store.selectedID) {
                    Text("Choose account").tag(nil as String?)
                    ForEach(s.accounts) { a in
                        Text("\(a.name) · \(percent(a.remaining))\(a.id == s.recommended ? " ★" : "")").tag(Optional(a.id))
                    }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if let recommended = s.recommended {
                Text("Recommended: \(recommended) · earliest expiry on an eligible account")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let a = store.selected {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(a.name).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(a.available.map { "\($0) resets saved" } ?? "Resets unknown").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(percent(a.remaining)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("100%").foregroundStyle(blue)
                        Spacer()
                        if let remaining = a.remaining {
                            Text("+\(Int(100 - remaining)) points").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 25, weight: .semibold))
                    if let regular = a.weeklyReset {
                        Text("Regular renewal in \(timeLeft(regular)) · \(dateText(regular))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack {
                        Text("Available resets").fontWeight(.semibold)
                        Spacer()
                        Text("Earliest expiry first")
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(a.credits) { credit in creditRow(credit) }
                    Divider()
                    Text("OpenAI selects the credit consumed. We choose the account; expiry order is a guide.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let hold = a.holdReason { Text(hold).font(.system(size: 11)).foregroundStyle(.orange) }
                    Button { store.confirm() } label: {
                        Text(store.busy ? "Please wait…" : "Use 1 reset · \(a.name)")
                            .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 3)
                    }.buttonStyle(.borderedProminent).tint(blue)
                        .disabled(store.busy || !a.eligible || store.stale || s.pending != nil)
                    Text("Spends one reset after checking availability again.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(s.pending ?? "At most 10% remaining, allowed by OpenAI, then earliest expiry. Wait if the weekly quota renews within an hour.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let store = Store()
    private var displayTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: QuotaView(store: store))
        popover.contentSize = NSSize(width: 400, height: 620)
        store.updated = { [weak self] in
            self?.updateTitle()
            if !UserDefaults.standard.bool(forKey: "HasShownSummary") {
                UserDefaults.standard.set(true, forKey: "HasShownSummary")
                self?.toggle()
            }
        }
        updateTitle()
        store.start()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.objectWillChange.send(); self?.updateTitle() }
        }
    }
    private func updateTitle() {
        let fraction = min(1, max(0, (store.snapshot?.total ?? 0) / Double(store.snapshot?.capacity ?? 400)))
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 18, height: 10), xRadius: 3, yRadius: 3).fill()
            NSColor.labelColor.setFill()
            if fraction > 0 {
                NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 18 * fraction, height: 10), xRadius: 3, yRadius: 3).fill()
            }
            return true
        }
        image.isTemplate = true
        item.button?.image = image
        item.button?.imagePosition = .imageLeading
        item.button?.title = " " + percent(store.snapshot?.total) + (store.stale || store.failed ? " ·" : "")
        item.button?.toolTip = "Weekly quota remaining: \(percent(store.snapshot?.total)) of \(store.snapshot?.capacity ?? 400)%"
        item.button?.setAccessibilityLabel("Codex quota, \(percent(store.snapshot?.total)) weekly remaining. Open account summary.")
    }
    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
@main struct QuotaBarMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "me.onmax.quota-bar")
        if others.contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
