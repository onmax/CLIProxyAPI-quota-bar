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
    @Published var expanded: Set<String> = []
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

struct QuotaView: View {
    @ObservedObject var store: Store
    private let blue = Color(red: 0.10, green: 0.38, blue: 0.95)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal.fill").font(.system(size: 23)).foregroundStyle(blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex").font(.system(size: 16, weight: .semibold))
                    Text("Your account pool").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: store.refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(store.busy).help("Refresh quota")
                Menu {
                    Button("Open dashboard", action: store.openDashboard)
                    Divider()
                    Button("Quit Quota Bar") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("More options")
            }.padding(.horizontal, 20).padding(.top, 19).padding(.bottom, 16)
            HStack(spacing: 4) {
                tab("Overview", symbol: "square.grid.2x2", active: !store.resetView) { store.resetView = false }
                tab("Reset", symbol: "arrow.counterclockwise", active: store.resetView) { store.preview() }
            }.padding(4).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let snapshot = store.snapshot {
                        if store.resetView { resetPanel(snapshot) } else { overview(snapshot) }
                    } else {
                        VStack(spacing: 12) {
                            if store.busy { ProgressView() }
                            Text(store.busy ? "Reading your account pool…" : "Your pool is unavailable")
                                .foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 220)
                    }
                    if let message = store.message {
                        Label(message, systemImage: store.failed ? "exclamationmark.circle" : "checkmark.circle")
                            .font(.system(size: 12)).foregroundStyle(store.failed ? .orange : .green)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
            Divider()
            HStack(spacing: 6) {
                if store.busy { ProgressView().controlSize(.mini) }
                Circle().fill(store.stale || store.failed ? .orange : .green).frame(width: 5, height: 5)
                Text(store.busy ? "Refreshing…" : (store.stale || store.failed ? "Last known data" : "Updated"))
                if let s = store.snapshot {
                    Text(Date(timeIntervalSince1970: s.updated), style: .time).monospacedDigit()
                }
                Spacer()
                Text("Every 5 min")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: 430, height: 690)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tab(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(active ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(active ? .primary : .secondary)
        }.buttonStyle(.plain)
    }
    private func overview(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("WEEKLY REMAINING").font(.system(size: 10, weight: .semibold)).tracking(1)
                    Spacer()
                    Text("\(s.accounts.count) PRO ACCOUNTS").font(.system(size: 9, weight: .medium)).opacity(0.8)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(percent(s.total)).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("/ \(s.capacity)%").font(.system(size: 18, weight: .medium)).opacity(0.65)
                    Spacer()
                }
                ProgressView(value: s.total ?? 0, total: Double(s.capacity)).tint(.white)
                HStack {
                    Text("Combined across your accounts")
                    Spacer()
                    let count = s.accounts.compactMap(\.available)
                    Text(count.count == s.accounts.count ? "\(count.reduce(0, +)) resets saved" : "Resets unknown")
                }.font(.system(size: 10)).opacity(0.9)
            }.foregroundStyle(.white).padding(18)
                .background(LinearGradient(colors: [blue, Color(red: 0.08, green: 0.29, blue: 0.77)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 15))
            HStack {
                Text("ACCOUNTS").font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Spacer()
                Text("Weekly remaining").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.top, 3)
            VStack(spacing: 0) {
                ForEach(Array(s.accounts.enumerated()), id: \.element.id) { index, account in
                    accountRow(account)
                    if index < s.accounts.count - 1 { Divider().padding(.horizontal, 14) }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            if let recommended = s.accounts.first(where: { $0.id == s.recommended }), let credit = recommended.nextCredit {
                Button { store.preview(recommended) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 22)).foregroundStyle(blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Next reset: \(recommended.name)").font(.system(size: 12, weight: .semibold))
                            Text("\(percent(recommended.remaining)) left · earliest credit expires in \(timeLeft(credit.expires))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(12).background(blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain)
            } else {
                Text(s.pending ?? "No account needs an eligible reset right now.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private func accountRow(_ a: Account) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(a.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(percent(a.remaining)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle((a.remaining ?? 0) > 10 ? blue : .orange)
            }
            ProgressView(value: a.remaining ?? 0, total: 100).tint((a.remaining ?? 0) > 10 ? blue : .orange)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let reset = a.weeklyReset {
                        Text("Renews in \(timeLeft(reset))").help(dateText(reset))
                    } else { Text(a.error ?? "Renewal unknown") }
                    Text(a.creditsError ?? (a.nextCredit.map { "Next reset expires \(dateText($0.expires))" } ?? "No saved resets"))
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    if !store.expanded.insert(a.id).inserted { store.expanded.remove(a.id) }
                } label: {
                    HStack(spacing: 4) {
                        Text(a.available.map { "\($0) resets" } ?? "Resets ?")
                        Image(systemName: store.expanded.contains(a.id) ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }.font(.system(size: 10, weight: .medium)).foregroundStyle(blue)
                }.buttonStyle(.plain).help("Show reset grants and expiry dates")
            }
            if store.expanded.contains(a.id) {
                ForEach(a.credits) { credit in creditRow(credit) }
                Button("Review reset for \(a.name)") { store.preview(a) }
                    .font(.system(size: 11)).buttonStyle(.link).padding(.top, 2)
            }
        }.padding(14)
    }
    private func creditRow(_ c: ResetCredit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Expires \(dateText(c.expires))").font(.system(size: 11, weight: .medium))
                Text(c.granted.map { "Granted \(dateText($0))" } ?? "Grant date unavailable").font(.system(size: 10)).foregroundStyle(.secondary)
                if !c.supported { Text("Not supported by this plan").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            Spacer(minLength: 0)
            Text(timeLeft(c.expires)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
    private func resetPanel(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Use a saved reset").font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            Text("Choose a depleted account. Keep newer resets for later.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(s.accounts) { a in
                    Button { store.selectedID = a.id } label: {
                        HStack(spacing: 10) {
                            Image(systemName: store.selectedID == a.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(store.selectedID == a.id ? blue : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(a.name).fontWeight(.semibold)
                                    if a.id == s.recommended {
                                        Text("RECOMMENDED").font(.system(size: 8, weight: .semibold)).foregroundStyle(blue)
                                    }
                                }.font(.system(size: 12))
                                Text(a.holdReason ?? "Earliest expiry \(a.nextCredit.map { timeLeft($0.expires) } ?? "unknown")")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            Spacer()
                            Text(percent(a.remaining)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                        }.padding(12).frame(maxWidth: .infinity)
                            .background(store.selectedID == a.id ? blue.opacity(0.07) : .clear)
                    }.buttonStyle(.plain)
                    if a.id != s.accounts.last?.id { Divider() }
                }
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            if let a = store.selected {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(a.name) · reset preview").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(a.available.map { "\($0) saved" } ?? "Unknown").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(percent(a.remaining)).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right").font(.system(size: 15)).foregroundStyle(.secondary)
                        Text("100%").foregroundStyle(blue)
                        Spacer()
                        if let remaining = a.remaining {
                            Text("+\(Int(100 - remaining)) points").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.font(.system(size: 29, weight: .semibold, design: .rounded))
                    Text("Expected weekly quota after one full reset").font(.system(size: 10)).foregroundStyle(.secondary)
                    if let regular = a.weeklyReset {
                        Text("Without a reset: renews in \(timeLeft(regular)) · \(dateText(regular))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text("AVAILABLE RESETS · EARLIEST EXPIRY FIRST").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(a.credits) { credit in creditRow(credit) }
                    Text("OpenAI chooses the credit consumed. The earliest expiry is shown first; a specific credit cannot be selected through this API.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let hold = a.holdReason { Text(hold).font(.system(size: 11)).foregroundStyle(.orange) }
                    Button { store.confirm() } label: {
                        Text(store.busy ? "Please wait…" : "Use 1 reset · \(a.name)")
                            .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).tint(blue)
                        .disabled(store.busy || !a.eligible || store.stale || s.pending != nil)
                    Text("This button spends one reset. Availability is checked again before it is applied.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(15).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(s.pending ?? "Recommendation: at most 10% remaining, allowed by OpenAI, then earliest expiry. Accounts renewing within an hour can wait.")
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
        popover.contentSize = NSSize(width: 430, height: 690)
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
                NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: max(3, 18 * fraction), height: 10), xRadius: 3, yRadius: 3).fill()
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
