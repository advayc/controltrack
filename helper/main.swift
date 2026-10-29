import SwiftUI
import AppKit
import IOKit
import CryptoKit

struct Session: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var start: Date
    var plannedEnd: Date
    var actualEnd: Date?
    var estimatedStart: Bool = false
}
struct Archive: Codable { var sessions: [Session] = []; var nextName: String = "" }
struct BlockState { var running: Bool; var end: Date? }
struct TrackerCommand: Decodable { var type: String; var id: UUID; var name: String }

func settingsPath() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let serial = IORegistryEntryCreateCFProperty(service, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String else { return nil }
    let digest = Insecure.SHA1.hash(data: Data(("SelfControlUserPreferences" + serial).utf8))
    return "/usr/local/etc/." + digest.map { String(format: "%02x", $0) }.joined() + ".plist"
}
func readState(path: String) throws -> BlockState? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let running = dict["BlockIsRunning"] as? Bool else { throw NSError(domain: "FocusLedger", code: 1, userInfo: [NSLocalizedDescriptionKey: "SelfControl's settings could not be read."]) }
    return BlockState(running: running, end: dict["BlockEndDate"] as? Date)
}
func durationText(_ seconds: TimeInterval) -> String {
    let mins = max(0, Int(seconds / 60)); let h = mins / 60; let m = mins % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var nextName = ""
    @Published var status = "Connecting to SelfControl…"
    @Published var running = false
    @Published var readError: String? = nil
    private var timer: Timer?
    private var archiveHealthy = true
    var onSessionStarted: ((UUID) -> Void)?
    let archiveURL: URL
    let statePath: String?
    init(path: String? = settingsPath(), archiveURL: URL? = nil, startTimer: Bool = true) {
        self.statePath = path
        self.archiveURL = archiveURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Focus Ledger/sessions.json")
        if FileManager.default.fileExists(atPath: self.archiveURL.path) {
            do {
                let data = try Data(contentsOf: self.archiveURL)
                let archive = try JSONDecoder().decode(Archive.self, from: data)
                sessions = archive.sessions; nextName = archive.nextName
            } catch {
                archiveHealthy = false
                status = "History unavailable"
                readError = "Could not read the existing session history. It has not been changed."
            }
        }
        if startTimer { startMonitoring() }
    }
    func startMonitoring() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
    }
    @discardableResult func save() -> Bool {
        guard archiveHealthy else { return false }
        do {
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Archive(sessions: sessions, nextName: nextName))
            try data.write(to: archiveURL, options: .atomic)
            return true
        } catch { readError = "Could not save session history: \(error.localizedDescription)"; return false }
    }
    func poll(now: Date = Date()) {
        guard archiveHealthy else { return }
        processCommands()
        guard let path = statePath else { status = "SelfControl unavailable"; readError = "Could not locate SelfControl's settings."; return }
        do {
            let block = try readState(path: path)
            if block == nil { status = "Ready for your next block"; running = false; return }
            apply(block!, now: now)
        } catch { status = "Connection unavailable"; readError = "Could not read SelfControl's state. History is preserved; tracking will retry." }
    }
    func apply(_ block: BlockState, now: Date) {
        guard archiveHealthy else { return }
        readError = nil
        if block.running {
            guard let end = block.end else { status = "Waiting for SelfControl…"; return }
            running = true; status = end > now ? "SelfControl block in progress" : "Waiting for SelfControl to finish"
            if let i = sessions.firstIndex(where: { $0.actualEnd == nil }) {
                if sessions[i].plannedEnd != end { sessions[i].plannedEnd = end; save() }
            } else {
                let chosen = nextName.trimmingCharacters(in: .whitespacesAndNewlines)
                let session = Session(name: chosen.isEmpty ? "Focus session" : chosen, start: now, plannedEnd: end, estimatedStart: false)
                sessions.insert(session, at: 0)
                nextName = ""; save()
                onSessionStarted?(session.id)
            }
        } else {
            running = false; status = "Ready for your next block"
            if let i = sessions.firstIndex(where: { $0.actualEnd == nil }) {
                sessions[i].actualEnd = max(sessions[i].start, min(now, sessions[i].plannedEnd)); save()
            }
        }
    }
    func rename(_ id: UUID, _ value: String) { if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i].name = value; save() } }
    var groupDirectory: URL { archiveURL.deletingLastPathComponent().appendingPathComponent("groups", isDirectory: true) }
    func groups() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: groupDirectory, includingPropertiesForKeys: nil)) ?? []
        let explicit = urls.filter { $0.pathExtension == "json" }.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(String.self, from: data)
        }
        let names = explicit + sessions.map { $0.name }
        var result: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && trimmed != "Focus session" && !result.contains(where: { $0.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) { result.append(trimmed) }
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    func addGroup(_ name: String) throws {
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        let url = groupDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(name).write(to: url, options: .atomic)
    }
    var commandDirectory: URL { archiveURL.deletingLastPathComponent().appendingPathComponent("commands", isDirectory: true) }
    func processCommands() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: commandDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url), let command = try? JSONDecoder().decode(TrackerCommand.self, from: data), command.type == "renameSession", let i = sessions.firstIndex(where: { $0.id == command.id }) else { continue }
            let name = command.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty && name.count <= 120 && name.rangeOfCharacter(from: .newlines) == nil else { continue }
            let existing = groups().first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            let canonical = existing ?? name
            if existing == nil { try? addGroup(canonical) }
            sessions[i].name = canonical
            if save() { try? FileManager.default.removeItem(at: url) }
        }
    }
    func focus(in day: Date, now: Date = Date()) -> TimeInterval {
        let cal = Calendar.current; let start = cal.startOfDay(for: day); let end = cal.date(byAdding: .day, value: 1, to: start)!
        return sessions.reduce(0) { total, session in
            let sessionEnd = session.actualEnd ?? min(now, session.plannedEnd)
            return total + max(0, min(end, sessionEnd).timeIntervalSince(max(start, session.start)))
        }
    }
}
struct Dashboard: View {
    @ObservedObject var store: Store
    let isDemo: Bool
    @State private var showHistory: Bool
    init(store: Store, isDemo: Bool = false) {
        self.store = store
        self.isDemo = isDemo
        _showHistory = State(initialValue: isDemo)
    }
    @State private var now = Date()
    let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var remaining: TimeInterval? { store.sessions.first(where: { $0.actualEnd == nil }).map { max(0, $0.plannedEnd.timeIntervalSince(now)) } }
    var statusColor: Color {
        guard store.running, let seconds = remaining else { return .secondary }
        return seconds <= 60 ? .red : seconds <= 300 ? .orange : .green
    }
    var remainingText: String {
        guard let seconds = remaining else { return "Waiting for SelfControl…" }
        let total = max(0, Int(ceil(seconds)))
        let hours = total / 3600, minutes = (total % 3600) / 60, remainder = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d remaining", hours, minutes, remainder) : String(format: "%d:%02d remaining", minutes, remainder)
    }
    var days: [Date] { (0..<7).reversed().compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) } }
    var groupTotals: [(name: String, seconds: TimeInterval)] {
        var sums: [String: TimeInterval] = [:]
        for session in store.sessions {
            let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = name.isEmpty ? "Focus session" : name
            sums[key, default: 0] += max(0, (session.actualEnd ?? min(now, session.plannedEnd)).timeIntervalSince(session.start))
        }
        return sums.map { (name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }
    var body: some View {
        VStack(spacing: 16) {
            if showHistory {
                HStack {
                    Button("Done") { showHistory = false }
                    Spacer()
                    Text(isDemo ? "Statistics · Example data" : "Statistics").font(.headline)
                    Spacer()
                    Text("\(store.sessions.count) sessions").font(.caption).foregroundColor(.secondary)
                }
                let values = days.map { store.focus(in: $0, now: now) }
                let maximum = max(values.max() ?? 0, 3600)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        VStack(spacing: 3) {
                            Text(durationText(values[index])).font(.caption2).foregroundColor(.secondary)
                            RoundedRectangle(cornerRadius: 2).fill(values[index] > 0 ? Color.accentColor : Color.secondary.opacity(0.15)).frame(height: max(3, CGFloat(values[index] / maximum) * 52))
                            Text(day.formatted(.dateTime.weekday(.abbreviated))).font(.caption2).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(height: 85, alignment: .bottom)
                if store.sessions.isEmpty {
                    Spacer(); Text("No sessions yet").foregroundColor(.secondary); Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            HStack { Text("Subjects / Groups").fontWeight(.semibold); Spacer() }.padding(.vertical, 8)
                            ForEach(groupTotals, id: \.name) { group in
                                HStack { Text(group.name); Spacer(); Text(durationText(group.seconds)).monospacedDigit().foregroundColor(.secondary) }.padding(.vertical, 5)
                            }
                            Divider().padding(.vertical, 8)
                            HStack { Text("Sessions").fontWeight(.semibold); Spacer() }.padding(.vertical, 4)
                            ForEach(store.sessions) { s in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        TextField("Subject or group", text: Binding(get: { store.sessions.first(where: { $0.id == s.id })?.name ?? "" }, set: { store.rename(s.id, $0) })).textFieldStyle(.plain).fontWeight(.medium)
                                        Text(s.start.formatted(date: .abbreviated, time: .shortened) + (s.actualEnd == nil ? " · In progress" : "")).font(.caption).foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(durationText((s.actualEnd ?? min(now, s.plannedEnd)).timeIntervalSince(s.start))).monospacedDigit().foregroundColor(.secondary)
                                }.padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }
                }
            } else {
                Spacer()
                Text(store.running ? "Block in progress" : "Ready for your next block").foregroundColor(statusColor)
                if store.running { Text(remainingText).font(.callout).monospacedDigit().foregroundColor(statusColor) }
                if let error = store.readError { Text(error).font(.caption).foregroundColor(.red) }
                else { Text("Start a block in SelfControl. You’ll be asked for a subject or group.").font(.callout).foregroundColor(.secondary).multilineTextAlignment(.center) }
                HStack(spacing: 12) {
                    Button("Open SelfControl") { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: NSHomeDirectory() + "/Applications/SelfControl.app"), configuration: NSWorkspace.OpenConfiguration()) }
                    Button("View Statistics") { showHistory = true }
                }.padding(.top, 4)
                Spacer()
            }
        }.padding(22).frame(minWidth: 430, minHeight: 250).onReceive(clock) { now = $0 }
    }
}
final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store: Store
    let isDemo: Bool
    var window: NSWindow!
    var statusItem: NSStatusItem?
    override init() {
        let demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--export-demo")
        isDemo = demo
        if demo {
            let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.json")
            let exampleStore = Store(path: nil, archiveURL: archive, startTimer: false)
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let minutes = [65, 120, 90, 0, 150, 110, 0]
            let subjects = ["Mathematics", "Biology", "Literature", "", "Mathematics", "Biology", ""]
            for index in minutes.indices where minutes[index] > 0 {
                let day = calendar.date(byAdding: .day, value: index - 6, to: startOfToday)!
                let start = calendar.date(byAdding: .hour, value: 9, to: day)!
                let end = start.addingTimeInterval(TimeInterval(minutes[index] * 60))
                exampleStore.sessions.insert(Session(name: subjects[index], start: start, plannedEnd: end, actualEnd: end), at: 0)
            }
            store = exampleStore
        } else {
            store = Store(startTimer: false)
        }
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: isDemo ? 440 : 330), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "SelfControl Tracker"; window.center(); window.delegate = self; window.isReleasedWhenClosed = false
        if isDemo { window.appearance = NSAppearance(named: .darkAqua) }
        window.contentView = NSHostingView(rootView: Dashboard(store: store, isDemo: isDemo))
        if !isDemo {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let iconURL = Bundle.main.url(forResource: "SelfControlIcon", withExtension: "icns"), let icon = NSImage(contentsOf: iconURL) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = false
                item.button?.image = icon
            } else {
                item.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "SelfControl Tracker")
            }
            item.button?.setAccessibilityLabel("Open SelfControl Tracker")
            item.button?.target = self
            item.button?.action = #selector(toggleWindow)
            statusItem = item
            store.onSessionStarted = { [weak self] id in self?.askForSubject(id) }
            store.startMonitoring()
        }
        if CommandLine.arguments.contains("--preview-prompt") { DispatchQueue.main.async { self.askForSubject(UUID()) } }
        if !CommandLine.arguments.contains("--background") { showWindow() }
        if let argument = CommandLine.arguments.firstIndex(of: "--export-demo"), argument + 1 < CommandLine.arguments.count {
            let destination = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let view = self.window.contentView, let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                view.cacheDisplay(in: view.bounds, to: representation)
                guard let composited = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: representation.pixelsWide, pixelsHigh: representation.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
                composited.size = view.bounds.size
                view.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: composited)
                    NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
                    view.bounds.fill()
                    let captured = NSImage(size: view.bounds.size)
                    captured.addRepresentation(representation)
                    captured.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                }
                guard let png = composited.representation(using: .png, properties: [:]) else { exit(1) }
                do { try png.write(to: destination, options: .atomic); NSApp.terminate(nil) }
                catch { NSLog("Could not export demo: %@", error.localizedDescription); exit(1) }
            }
        }
    }
    func askForSubject(_ id: UUID) {
        let alert = NSAlert(); alert.messageText = "What are you focusing on?"; alert.informativeText = "Enter a subject or group for this SelfControl block."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Skip")
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        box.placeholderString = "Subject or group"
        let names = store.groups()
        box.addItems(withObjectValues: names); alert.accessoryView = box
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = box.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                let existing = names.first { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                let canonical = existing ?? name
                if existing == nil { try? store.addGroup(canonical) }
                store.rename(id, canonical)
            }
        }
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggleWindow() { if window.isVisible && window.isKeyWindow { window.close() } else { showWindow() } }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
}
if CommandLine.arguments.contains("--self-test") {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions.json")
    let s = Store(path: nil, archiveURL: path, startTimer: false)
    let start = Date(timeIntervalSince1970: 1800000000); let end = start.addingTimeInterval(3600)
    var prompts = 0; s.onSessionStarted = { _ in prompts += 1 }
    s.nextName = "Study"; s.apply(BlockState(running: true, end: end), now: start)
    precondition(s.sessions.count == 1 && s.sessions[0].name == "Study")
    s.apply(BlockState(running: true, end: end.addingTimeInterval(600)), now: start.addingTimeInterval(10))
    precondition(s.sessions.count == 1 && s.sessions[0].plannedEnd == end.addingTimeInterval(600) && prompts == 1)
    s.apply(BlockState(running: false, end: nil), now: end.addingTimeInterval(620))
    precondition(s.sessions[0].actualEnd == end.addingTimeInterval(600))
    let fixture = path.deletingLastPathComponent().appendingPathComponent("block.plist")
    let fixtureData = try! PropertyListSerialization.data(fromPropertyList: ["BlockIsRunning": true, "BlockEndDate": end], format: .binary, options: 0)
    try! fixtureData.write(to: fixture)
    let parsed = try! readState(path: fixture.path)
    precondition(parsed?.running == true && parsed?.end == end)
    precondition(settingsPath() != nil)
    try! s.addGroup("Calculus")
    let restored = Store(path: nil, archiveURL: path, startTimer: false)
    precondition(restored.sessions.count == 1 && restored.sessions[0].name == "Study")
    precondition(restored.groups().contains("Calculus") && restored.groups().contains("Study"))
    try! FileManager.default.createDirectory(at: restored.commandDirectory, withIntermediateDirectories: true)
    let commandPath = restored.commandDirectory.appendingPathComponent("test.json")
    let commandData = try! JSONSerialization.data(withJSONObject: ["type": "renameSession", "id": restored.sessions[0].id.uuidString, "name": "calculus"])
    try! commandData.write(to: commandPath)
    restored.processCommands()
    precondition(restored.sessions[0].name == "Calculus" && !FileManager.default.fileExists(atPath: commandPath.path))
    precondition(Store(path: nil, archiveURL: path, startTimer: false).sessions[0].name == "Calculus")
    let corruptPath = path.deletingLastPathComponent().appendingPathComponent("corrupt.json")
    try! Data("not a valid archive".utf8).write(to: corruptPath)
    let corruptStore = Store(path: nil, archiveURL: corruptPath, startTimer: false)
    corruptStore.apply(BlockState(running: true, end: end), now: start)
    precondition((try! Data(contentsOf: corruptPath)) == Data("not a valid archive".utf8))
    try? FileManager.default.removeItem(at: path.deletingLastPathComponent()); print("Self-test passed")
} else {
    let app = NSApplication.shared; let delegate = Delegate(); app.delegate = delegate; app.run()
}
